import Foundation

@main
enum TurnTokenStateTests {
    static func main() {
        var state = TurnTokenState()
        func start(_ id: String) {
            state.consume(type: "event_msg", payload: ["type": "task_started", "turn_id": id])
        }
        func usage(_ total: Any, last: Int = 10, turn: String? = nil) {
            var payload: [String: Any] = ["type": "token_count", "info": [
                "total_token_usage": ["total_tokens": total],
                "last_token_usage": ["total_tokens": last]
            ]]
            if let turn { payload["turn_id"] = turn }
            state.consume(type: "event_msg", payload: payload)
        }
        start("one")
        usage(100, last: 100)
        precondition(state.total == 100)
        usage(100, last: 100)
        precondition(state.total == 100, "duplicates must not accumulate")
        usage(180, last: 80)
        precondition(state.total == 180)
        start("two")
        precondition(state.total == nil, "new turns await measured usage")
        usage(210)
        precondition(state.total == 30)
        start("two")
        state.consume(type: "turn_context", payload: ["turn_id": "two"])
        usage(240)
        precondition(state.total == 60, "duplicate starts and context do not reset baseline")
        usage(999, turn: "one")
        precondition(state.total == 60, "foreign turn ignored")
        usage(true)
        usage(-1)
        usage(4.5)
        usage(Double.infinity)
        precondition(state.total == 60, "invalid counters ignored")
        state.consume(type: "event_msg", payload: ["type": "task_complete", "turn_id": "two"])
        usage(250)
        precondition(state.total == 70, "late final usage retained")
        usage(20)
        precondition(state.total == nil, "counter reset invalidates completeness")
        usage(40, last: 40)
        precondition(state.total == nil, "reset cannot regain a false baseline")
        start("three")
        usage(50)
        precondition(state.total == 10, "subsequent turn can recover baseline")
        var tail = TurnTokenState()
        tail.consume(type: "turn_context", payload: ["turn_id": "tail"])
        tail.consume(type: "event_msg", payload: ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 500], "last_token_usage": ["total_tokens": 500]
        ]])
        precondition(tail.total == nil, "truncated mid-turn tail is not whole-turn usage")
        var prefix = TurnTokenState()
        prefix.consume(type: "event_msg", payload: ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 500]
        ]])
        prefix.consume(type: "turn_context", payload: ["turn_id": "unknown-boundary"])
        prefix.consume(type: "event_msg", payload: ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 600]
        ]])
        precondition(prefix.total == nil, "context after unowned tokens cannot prove a turn baseline")
        var isolated = TurnTokenState()
        isolated.consume(type: "event_msg", payload: ["type": "task_started"])
        isolated.consume(type: "turn_context", payload: ["turn_id": "first"])
        isolated.consume(type: "event_msg", payload: ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 0], "last_token_usage": ["total_tokens": 0]
        ]])
        precondition(isolated.total == 0, "zero is distinct from unknown; legacy start supported")
        precondition(state.total == 10, "sessions remain isolated")
        precondition(MenuBarTokenFormatter.shortCount(999_950) == "1.0M")
        precondition(MenuBarTokenFormatter.shortCount(0) == "0K")
        precondition(MenuBarTokenFormatter.shortCount(1) == "<0.1K")
        precondition(MenuBarTokenFormatter.shortCount(750) == "0.8K")
        precondition(MenuBarTokenFormatter.shortCount(1_234_567_890) == "1.2B")
        precondition(TurnTokenUsage(sessionID: "s", turnID: "t", total: 257800).label == "本轮 257.8K Token")
        let measured = TurnTokenUsage(sessionID: "s", turnID: "t", total: 257800, isCompleted: true)
        let title = MenuBarTokenFormatter.title(status: "执行中", project: "项目A", usage: measured, quota: 18, projectCount: 3)
        precondition(title == "执行中 · 项目A · ＋2个项目 · 本轮 257.8K Token · 余 18%")
        let unknown = TurnTokenUsage(sessionID: "s", turnID: "t", total: nil)
        precondition(!MenuBarTokenFormatter.title(status: "执行中", project: nil, usage: unknown, quota: nil).contains("0 Token"))
        var receipt = MenuBarTokenReceipt()
        let now = Date(timeIntervalSince1970: 100)
        precondition(!receipt.resolve(usage: unknown, now: now))
        precondition(receipt.resolve(usage: measured, now: now))
        precondition(!receipt.resolve(usage: measured, now: now.addingTimeInterval(6)))
        precondition(!receipt.resolve(usage: measured, now: now.addingTimeInterval(60)))
        precondition(receipt.resolve(usage: .init(sessionID: "s2", turnID: "t", total: 20, isCompleted: true), now: now.addingTimeInterval(60)))
        state.consume(type: "event_msg", payload: ["type": "task_complete", "turn_id": "other"])
        precondition(!state.isCompleted)
        state.consume(type: "event_msg", payload: ["type": "task_complete", "turn_id": "three"])
        precondition(state.isCompleted)
        start("four")
        precondition(!state.isCompleted)
        print("TurnTokenState: 32 regression checks passed")
    }
}
