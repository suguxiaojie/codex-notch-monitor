import AppKit

@main
enum StatusItemLayoutTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        func measure(_ text: String) -> Double {
            Double((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let long = "执行中 · 一个非常长的项目名称 · ＋12个项目 · 本轮 999.9M Token · 余 100%"
        let compact = "执行 ＋12 · 999.9M Token · 余 100%"
        let minimal = "999.9M Token ＋12"
        let budget = StatusItemLayout.budget(menuRegionWidth: 772)
        check(budget == 193)
        let result = StatusItemLayout.resolve(candidates: [long, compact, minimal], budget: budget, measure: measure)
        check(result.title != long)
        check(result.width <= budget)
        check(result.title == minimal)
        for width in [0.0, 32, 48, 92, 120, 193, 240] {
            for titles in [[long, compact, minimal], ["额度同步中"], ["余 17%"], [String(repeating: "🧑‍💻", count: 100)], []] {
                let fit = StatusItemLayout.resolve(candidates: titles, budget: width, measure: measure)
                check(fit.width >= 32 && fit.width.isFinite)
                check(fit.title.isEmpty || fit.width <= width)
            }
        }
        check(StatusItemLayout.budget(menuRegionWidth: nil) == 120)
        check(StatusItemLayout.budget(menuRegionWidth: .nan) == 120)
        check(StatusItemLayout.budget(menuRegionWidth: 10000) == 240)
        check(StatusItemLayout.resolve(candidates: [long], budget: 240, measure: measure).title.isEmpty)
        // Content transitions always produce a finite fixed width. No dependence
        // on a previous button frame or intermediate intrinsicContentSize.
        let small = StatusItemLayout.resolve(candidates: ["1.2K Token"], budget: budget, measure: measure)
        let restored = StatusItemLayout.resolve(candidates: [long, compact, minimal], budget: budget, measure: measure)
        check(small.width < restored.width)
        check(restored == result)
        let priority = StatusItemLayout.taskTitles(status: "待确认", project: "项目A", projectCount: 3,
                                                   token: "本轮 1.2M", quota: "17%")
        check(priority[0] == "17% · 待确认 · 项目A ＋2 · 本轮 1.2M")
        check(priority[1] == "17% · 待确认 · 项目A ＋2")
        check(priority[2] == "17% · 待确认 · 本轮 1.2M")
        check(priority[3] == "17% · 待确认 ＋2")
        check(priority.allSatisfy { $0.hasPrefix("17% · 待确认") })
        let single = StatusItemLayout.taskTitles(status: "执行", project: "项目A", projectCount: 1,
                                                 token: "本轮 1.2M", quota: "17%")
        check(single[1] == "17% · 执行 · 本轮 1.2M")
        check(single[2] == "17% · 执行 · 项目A")
        let unknown = StatusItemLayout.taskTitles(status: "待确认", project: "项目A", projectCount: 2,
                                                  token: nil, quota: "17%")
        check(unknown.allSatisfy { !$0.contains("0K") })
        for budget in [80.0, 120, 160, 193, 240] {
            let chosen = StatusItemLayout.resolve(candidates: priority, budget: budget, measure: measure)
            check(chosen.title.isEmpty || chosen.title.contains("待确认"))
        }
        let pages = StatusItemRotation.fittingPages(["执行 · 项目A", "执行 · 本轮 1.2M", "执行 · 余 17%"], budget: 193, measure: measure)
        check(pages.count == 3)
        var rotation = StatusItemRotation()
        check(rotation.configure(identity: "session/turn", pages: pages))
        check(rotation.title == pages[0])
        check(!rotation.advance(hovered: true))
        check(rotation.index == 0)
        check(rotation.advance(hovered: false))
        check(rotation.title == pages[1])
        var updated = pages
        updated[1] = "执行 · 本轮 1.3M"
        check(!rotation.configure(identity: "session/turn", pages: updated))
        check(rotation.title == updated[1])
        let workingPages = updated.map { $0.replacingOccurrences(of: "执行", with: "思考") }
        check(!rotation.configure(identity: "session/turn", pages: workingPages))
        check(rotation.index == 1)
        check(rotation.advance(hovered: false))
        check(rotation.advance(hovered: false))
        check(rotation.index == 0)
        _ = rotation.advance(hovered: false)
        check(rotation.configure(identity: "other-session/turn", pages: pages))
        check(rotation.index == 0)
        rotation.configure(identity: "other-session/turn", pages: [])
        check(!rotation.advance(hovered: false) && rotation.title == nil)
        check(StatusItemRotation.fittingPages(pages, budget: 32, measure: measure).isEmpty)
        check(StatusItemRotation.fittingPages(["执行", "执行"], budget: 193, measure: measure).isEmpty)
        let detailedBudget = StatusItemLayout.budget(menuRegionWidth: 772, detailed: true)
        check(detailedBudget > budget)
        check(detailedBudget <= 420)
        check(StatusItemLayout.budget(menuRegionWidth: 10000, detailed: true) == 420)
        let projectName = "Codex额度监控macbook插件。"
        let detailedName = StatusItemLayout.projectTitle(status: "思考", project: projectName, budget: 301, measure: measure)!
        check(detailedName.contains(projectName))
        let shortName = StatusItemLayout.projectTitle(status: "思考", project: projectName, suffix: " ＋2", budget: 193, measure: measure)!
        check(shortName.contains("…"))
        check(shortName.hasSuffix(" ＋2"))
        check(shortName != "思考 · Codex ＋2")
        check(measure(shortName) + 36 <= 193)
        for text in [projectName, "项目", "WWWWWWWWWWWWWWWWWWWWWW", "🧑‍💻🧑‍💻🧑‍💻🧑‍💻🧑‍💻", "iiiiiiiiiiiiiiiiiiiiii"] {
            for width in [0.0, 50, 120] {
                let clipped = StatusItemLayout.truncated(text, width: width, measure: measure)
                check(clipped.isEmpty || measure(clipped) <= width)
                check(clipped.isEmpty || clipped == text || clipped.hasSuffix("…"))
            }
        }
        check(StatusItemLayout.projectTitle(status: "等待确认", project: projectName, budget: 32, measure: measure) == nil)
        var capacity = StatusItemCapacity()
        let capacityStart = Date(timeIntervalSince1970: 1_800_000_000)
        check(capacity.constrain(386, context: "automatic/screen") == 386)
        check(capacity.observe(width: 289, onMenuBar: true, occluded: true, now: capacityStart))
        check(capacity.constrain(386, context: "automatic/screen") == 216.75)
        check(capacity.recoveryDelay(after: capacityStart) == StatusItemCapacity.recoveryInterval)
        check(!capacity.observe(width: 216.75, onMenuBar: true, occluded: false,
                                now: capacityStart.addingTimeInterval(7)))
        check(capacity.observe(width: 216.75, onMenuBar: true, occluded: false,
                               now: capacityStart.addingTimeInterval(8)))
        let recovered = capacity.constrain(386, context: "automatic/screen")
        check(recovered > 216.75 && recovered <= 386)
        check(capacity.observe(width: recovered, onMenuBar: true, occluded: true,
                               now: capacityStart.addingTimeInterval(8.5)))
        check(capacity.constrain(386, context: "automatic/screen") == 216.75)
        check(capacity.recoveryDelay(after: capacityStart.addingTimeInterval(8.5))
              == StatusItemCapacity.failedRecoveryInterval)
        capacity.reconsiderRecovery(now: capacityStart.addingTimeInterval(9))
        check(capacity.recoveryDelay(after: capacityStart.addingTimeInterval(9)) == 0)
        check(capacity.constrain(386, context: "detailed/screen") == 386)
        check(capacity.recoveryDelay(after: capacityStart) == nil)
        check(!capacity.observe(width: 123, onMenuBar: true, occluded: false))
        check(!capacity.observe(width: 100, onMenuBar: false, occluded: true))
        check(!capacity.observe(width: 32, onMenuBar: true, occluded: true))
        check(capacity.constrain(193, context: "automatic/screen") == 193)
        let visualQuota = StatusItemLayout.taskTitles(status: "思考", project: "项目A", projectCount: 1,
                                                       token: "本轮 6.5M", quota: "14%")
        check(visualQuota == [
            "14% · 思考 · 项目A · 本轮 6.5M",
            "14% · 思考 · 本轮 6.5M",
            "14% · 思考 · 项目A",
            "14% · 思考"
        ])
        check(visualQuota.allSatisfy { $0.hasPrefix("14% · 思考") })
        check(visualQuota.allSatisfy { !$0.contains("余 14%") && !$0.contains("小时") })
        let idlePages = StatusItemRotation.fittingPages([], budget: 193, measure: measure)
        check(idlePages.isEmpty)
        print("StatusItemLayout: \(checks) checks passed")
    }
}
