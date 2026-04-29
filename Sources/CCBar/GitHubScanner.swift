import Foundation

enum CheckState: String {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error   = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
    case none = ""
}

enum ReviewDecision: String {
    case approved          = "APPROVED"
    case changesRequested  = "CHANGES_REQUESTED"
    case reviewRequired    = "REVIEW_REQUIRED"
    case none = ""
}

enum Mergeability: String {
    case mergeable   = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown     = "UNKNOWN"
}

struct GitHubPR: Identifiable, Hashable {
    let id: String                 // "owner/repo#number"
    let number: Int
    let title: String
    let repo: String               // "owner/repo"
    let url: String
    let updatedAt: Date
    let isDraft: Bool
    let review: ReviewDecision
    let check: CheckState
    let mergeable: Mergeability

    var isReadyToMerge: Bool {
        !isDraft
            && check == .success
            && review == .approved
            && mergeable == .mergeable
    }
}

struct ReviewRequest: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let repo: String
    let url: String
    let createdAt: Date
}

struct FailedRun: Identifiable, Hashable {
    let id: String           // "<repo>#<runID>"
    let runId: Int64
    let repo: String         // "owner/repo"
    let workflow: String     // "CI", "Deploy", etc.
    let branch: String
    let actor: String
    let url: String
    let createdAt: Date
}

struct DependabotAlert: Identifiable, Hashable {
    let id: String           // "<repo>#<number>"
    let number: Int
    let repo: String
    let severity: String     // "critical" | "high" | "medium" | "low"
    let summary: String
    let packageName: String
    let url: String
}

struct GitHubSnapshot {
    let viewerLogin: String
    let myPRs: [GitHubPR]
    let reviewQueue: [ReviewRequest]
    let failedRuns: [FailedRun]
    let dependabotAlerts: [DependabotAlert]
    let isAuthenticated: Bool
}

final class GitHubScanner {
    func scan(repos: [String]) -> GitHubSnapshot {
        guard authStatus() else {
            return GitHubSnapshot(viewerLogin: "", myPRs: [], reviewQueue: [],
                                  failedRuns: [], dependabotAlerts: [],
                                  isAuthenticated: false)
        }
        guard let data = runGh(["api", "graphql", "-f", "query=\(graphqlQuery)"]),
              let parsed = try? JSONDecoder.iso.decode(Response.self, from: data)
        else {
            return GitHubSnapshot(viewerLogin: "", myPRs: [], reviewQueue: [],
                                  failedRuns: [], dependabotAlerts: [],
                                  isAuthenticated: true)
        }

        let viewerLogin = parsed.data.viewer.login

        let myPRs: [GitHubPR] = parsed.data.viewer.pullRequests.nodes.map { raw in
            GitHubPR(
                id: "\(raw.repository.nameWithOwner)#\(raw.number)",
                number: raw.number,
                title: raw.title,
                repo: raw.repository.nameWithOwner,
                url: raw.url,
                updatedAt: raw.updatedAt,
                isDraft: raw.isDraft,
                review: ReviewDecision(rawValue: raw.reviewDecision ?? "") ?? .none,
                check: CheckState(rawValue: raw.statusCheckRollup?.state ?? "") ?? .none,
                mergeable: Mergeability(rawValue: raw.mergeable) ?? .unknown
            )
        }

        let reviewQueue: [ReviewRequest] = parsed.data.search.nodes.compactMap { raw in
            guard let number = raw.number,
                  let title = raw.title,
                  let url = raw.url,
                  let createdAt = raw.createdAt,
                  let repo = raw.repository?.nameWithOwner
            else { return nil }
            return ReviewRequest(
                id: "\(repo)#\(number)",
                number: number,
                title: title,
                repo: repo,
                url: url,
                createdAt: createdAt
            )
        }

        // Per-repo REST calls for Actions runs and Dependabot alerts. We do
        // these sequentially to keep code simple — the caller already throttles
        // GitHub scans to once a minute.
        var failedRuns: [FailedRun] = []
        var alerts: [DependabotAlert] = []
        for repo in repos {
            failedRuns.append(contentsOf: fetchFailedRuns(repo: repo, viewerLogin: viewerLogin))
            alerts.append(contentsOf: fetchDependabotAlerts(repo: repo))
        }

        return GitHubSnapshot(
            viewerLogin: viewerLogin,
            myPRs: myPRs,
            reviewQueue: reviewQueue,
            failedRuns: failedRuns.sorted { $0.createdAt > $1.createdAt },
            dependabotAlerts: alerts.sorted { severityRank($0.severity) > severityRank($1.severity) },
            isAuthenticated: true
        )
    }

    // Surfaces only *currently* failing workflows: we look at the most recent
    // completed run per (workflow, branch) and keep it only if its conclusion
    // was `failure`. Historical failures that have since been re-run
    // successfully don't appear. Filtered further to runs on `main` or runs
    // authored by the viewer.
    private func fetchFailedRuns(repo: String, viewerLogin: String) -> [FailedRun] {
        let path = "/repos/\(repo)/actions/runs?status=completed&per_page=50"
        guard let data = runGh(["api", path]),
              let parsed = try? JSONDecoder.iso.decode(RunsResponse.self, from: data)
        else { return [] }

        // Sort newest first, then take only the latest per (workflow, branch).
        let sorted = parsed.workflow_runs.sorted { $0.created_at > $1.created_at }
        var seenGroup = Set<String>()
        var latestPerGroup: [RawRun] = []
        for run in sorted {
            let key = "\(run.name)\u{1F}\(run.head_branch)"
            if seenGroup.insert(key).inserted {
                latestPerGroup.append(run)
            }
        }

        return latestPerGroup
            .filter { $0.conclusion == "failure" }
            .filter { $0.head_branch == "main" || $0.actor.login == viewerLogin }
            .map { raw in
                FailedRun(
                    id: "\(repo)#\(raw.id)",
                    runId: raw.id,
                    repo: repo,
                    workflow: raw.name,
                    branch: raw.head_branch,
                    actor: raw.actor.login,
                    url: raw.html_url,
                    createdAt: raw.created_at
                )
            }
    }

    // Dependabot alerts. Returns [] silently if user lacks access (403/404).
    private func fetchDependabotAlerts(repo: String) -> [DependabotAlert] {
        let path = "/repos/\(repo)/dependabot/alerts?state=open&per_page=20"
        guard let data = runGh(["api", path]),
              let parsed = try? JSONDecoder.iso.decode([RawAlert].self, from: data)
        else { return [] }
        return parsed.map { raw in
            DependabotAlert(
                id: "\(repo)#\(raw.number)",
                number: raw.number,
                repo: repo,
                severity: raw.security_advisory.severity,
                summary: raw.security_advisory.summary,
                packageName: raw.security_vulnerability.package.name,
                url: raw.html_url
            )
        }
    }

    private func severityRank(_ s: String) -> Int {
        switch s.lowercased() {
        case "critical": return 4
        case "high":     return 3
        case "medium":   return 2
        case "low":      return 1
        default:         return 0
        }
    }

    func authStatus() -> Bool {
        runGh(["auth", "status"]) != nil
    }

    private func runGh(_ args: [String]) -> Data? {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["gh"] + args
        // Apps launched from Finder/Dock have a minimal PATH; gh is typically
        // in /opt/homebrew/bin (Apple silicon) or /usr/local/bin (Intel).
        var env = ProcessInfo.processInfo.environment
        let extras = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"]).map { "\($0):\(extras)" } ?? extras
        task.environment = env

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return data
    }

    private let graphqlQuery = """
    query {
      viewer {
        login
        pullRequests(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url createdAt updatedAt isDraft
            reviewDecision mergeable
            repository { nameWithOwner }
            statusCheckRollup { state }
          }
        }
      }
      search(query: "is:open is:pr review-requested:@me", type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number title url createdAt
            repository { nameWithOwner }
          }
        }
      }
    }
    """

    // GraphQL response decoding
    private struct Response: Decodable { let data: DataField }
    private struct DataField: Decodable {
        let viewer: Viewer
        let search: SearchField
    }
    private struct Viewer: Decodable {
        let login: String
        let pullRequests: PRNodes
    }
    private struct PRNodes: Decodable { let nodes: [RawPR] }
    private struct SearchField: Decodable { let nodes: [RawSearchNode] }
    private struct RepoRef: Decodable { let nameWithOwner: String }
    private struct CheckRollup: Decodable { let state: String }
    private struct RawPR: Decodable {
        let number: Int
        let title: String
        let url: String
        let createdAt: Date
        let updatedAt: Date
        let isDraft: Bool
        let reviewDecision: String?
        let mergeable: String
        let repository: RepoRef
        let statusCheckRollup: CheckRollup?
    }
    private struct RawSearchNode: Decodable {
        let number: Int?
        let title: String?
        let url: String?
        let createdAt: Date?
        let repository: RepoRef?
    }

    // REST: workflow runs
    private struct RunsResponse: Decodable {
        let workflow_runs: [RawRun]
    }
    private struct RawRun: Decodable {
        let id: Int64
        let name: String
        let head_branch: String
        let html_url: String
        let created_at: Date
        let conclusion: String?
        let actor: RunActor
    }
    private struct RunActor: Decodable {
        let login: String
    }

    // REST: dependabot alerts
    private struct RawAlert: Decodable {
        let number: Int
        let html_url: String
        let security_advisory: RawAdvisory
        let security_vulnerability: RawVulnerability
    }
    private struct RawAdvisory: Decodable {
        let summary: String
        let severity: String
    }
    private struct RawVulnerability: Decodable {
        let package: RawPackage
    }
    private struct RawPackage: Decodable {
        let name: String
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
