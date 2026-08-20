import Combine
import Foundation

// 홈 대시보드가 필요한 서버 데이터를 한 곳에서 모은다.
//
// 서버의 `/parents/{parentId}/*`는 건강 주체 한 명을 기준으로 한다. 자녀 계정은
// 접근 가능한 부모의 userId를, 부모 계정은 자기 id를 넣는다. 화면에서 대상을 바꾸면
// `subjectId`만 갈아끼우고 다시 불러온다.
@MainActor
final class HomeDashboardModel: ObservableObject {
    @Published private(set) var subjectId: String?
    @Published private(set) var subjectName: String = ""
    @Published private(set) var report: CollogAPI.Report?
    @Published private(set) var questions: [CollogAPI.Question] = []
    @Published private(set) var calls: [CollogAPI.CallSummary] = []
    @Published private(set) var baselines: [CollogAPI.Baseline] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let session = AppSession.shared

    /// 마지막으로 분석까지 끝난 통화. 히어로의 `+N일차` 계산 기준이다.
    var lastAnalyzedCallAt: Date? {
        calls.filter(\.isAnalyzed).compactMap(\.startedAtDate).max()
    }

    /// 마지막 통화 이후 지난 일수. 통화 기록이 없으면 nil이라 숫자를 만들지 않는다.
    var daysSinceLastCall: Int? {
        guard let last = lastAnalyzedCallAt else { return nil }
        return Calendar.current.dateComponents([.day], from: last, to: Date()).day
    }

    /// 카드에 그릴 추이. 서버가 준 음향 지표 중 점이 2개 이상인 것만 쓴다.
    var primaryTrend: CollogAPI.Report.Trend? {
        report?.acousticTrends.first { $0.points.count >= 2 }
    }

    /// 추이 아래에 깔 회색 참조선 값(98:21622). 그리는 지표와 같은 지표의 ANCHOR 기준선을
    /// 쓴다. 시간대별로 따로 잡히므로 표본이 가장 많은 것을 고른다. 아직 READY가 아니면
    /// 비교할 기준이 없다는 뜻이라 nil을 주고 참조선을 그리지 않는다.
    var primaryBaselineMedian: Double? {
        guard let metric = primaryTrend?.metric else { return nil }
        return baselines
            .filter { $0.metric == metric && $0.kind == "ANCHOR" && $0.isReady }
            .max { $0.sampleCount < $1.sampleCount }?
            .median
    }

    func selectSubject(id: String, name: String) async {
        subjectId = id
        subjectName = name
        await reload()
    }

    /// 현재 계정에 맞는 기본 건강 주체를 고르고 데이터를 불러온다.
    func loadInitial() async {
        await session.refreshMembers()
        guard let user = session.user else { return }
        if user.role == "PARENT" {
            await selectSubject(id: user.id, name: user.name)
            return
        }
        // 자녀 계정은 통화 가능한(= 계정이 연결된) 가족을 먼저 본다.
        guard let member = session.members.first(where: { $0.userId != nil }),
              let memberUserId = member.userId else {
            subjectId = nil
            return
        }
        await selectSubject(id: memberUserId, name: member.name)
    }

    func reload() async {
        guard let subjectId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 한 곳이 실패해도 나머지는 보여준다. 실패한 영역만 비운다.
        async let reportTask = CollogAPI.report(parentId: subjectId, period: "WEEKLY")
        async let questionsTask = CollogAPI.dailyQuestions(parentId: subjectId)
        async let callsTask = CollogAPI.calls(parentId: subjectId)
        async let baselinesTask = CollogAPI.baselines(parentId: subjectId)

        var failures: [String] = []
        do { report = try await reportTask } catch {
            report = nil
            failures.append("리포트: \(error.localizedDescription)")
        }
        do { questions = try await questionsTask } catch {
            questions = []
            failures.append("질문: \(error.localizedDescription)")
        }
        do { calls = try await callsTask } catch {
            calls = []
            failures.append("통화 기록: \(error.localizedDescription)")
        }
        // 참조선은 보조 정보라 실패해도 화면 전체를 막지 않는다. 선만 빠진다.
        baselines = (try? await baselinesTask) ?? []
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}
