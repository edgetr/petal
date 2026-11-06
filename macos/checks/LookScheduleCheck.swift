import Foundation

// Checks LookSchedule.swift: when the dock looks at the windows again. Run with macos/checks/run.sh.
@main
struct LookScheduleCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    /// Plays events through a schedule the way DockController does: a look takes `lookTime`, a finished look may
    /// start the next at once, and the trailing timer fires when it's due. Returns when each look started.
    static func play(_ events: [(Double, LookSchedule.Cause)], lookTime: Double = 0.01, until end: Double = 10) -> [Double] {
        var schedule = LookSchedule()
        var starts: [Double] = []
        var lookEnds: Double?
        var queue = events.sorted { $0.0 < $1.0 }
        var now = 0.0
        while now <= end {
            // Whatever comes first: the look in flight ending, the trailing look, or the next event.
            let next = [lookEnds, schedule.due, queue.first?.0].compactMap { $0 }.min()
            guard let next, next <= end else { break }
            now = next
            if let ends = lookEnds, ends <= now {
                lookEnds = nil
                if schedule.finished(at: now) { starts.append(now); lookEnds = now + lookTime }
            } else if let due = schedule.due, due <= now, queue.first.map({ $0.0 > now }) ?? true {
                if schedule.fire(at: now) { starts.append(now); lookEnds = now + lookTime }
            } else if let event = queue.first {
                queue.removeFirst()
                if schedule.note(event.1, at: now) { starts.append(now); lookEnds = now + lookTime }
            }
        }
        return starts
    }

    static func main() {
        // One window opens: a look at once, and one after, for a window the server lists late.
        var starts = play([(1, .window)])
        expect(starts.first == 1, "a new window is looked at at once", "\(starts)")
        expect(starts.count == 2 && abs(starts[1] - (1 + LookSchedule.followUp)) < 0.001, "and once more just after", "\(starts)")

        // Ten windows in a burst (a browser restoring its session): three looks, the first at once.
        starts = play((0..<10).map { (2 + Double($0) * 0.005, LookSchedule.Cause.window) })
        expect(starts.first == 2, "a burst starts a look at once", "\(starts)")
        expect(starts.count == 3, "a burst of ten becomes three looks", "\(starts)")
        expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= LookSchedule.gap - 0.001 }, "looks are a gap apart", "\(starts)")
        expect((starts.last ?? 0) >= 2.045 + LookSchedule.followUp - 0.001, "the last look comes after the burst's last event", "\(starts)")

        // A window dragged for a second (60 moves): no look during the drag, one once it stops.
        starts = play((0..<60).map { (3 + Double($0) / 60, LookSchedule.Cause.movement) })
        expect(starts.count == 1, "a drag is one look", "\(starts)")
        expect(abs((starts.first ?? 0) - (3 + 59.0 / 60 + LookSchedule.settle)) < 0.001, "after the window stops", "\(starts)")

        // The timer doesn't pile up behind a slow look; an event during one gets a look right after it.
        starts = play([(1, .poll), (1.1, .poll), (1.2, .poll)], lookTime: 0.5)
        expect(starts == [1], "polls during a look are dropped", "\(starts)")
        starts = play([(1, .now), (1.1, .now), (1.2, .now)], lookTime: 0.5)
        expect(starts == [1, 1.5], "events during a look become one look after it", "\(starts)")
        starts = play([(1, .now), (1.02, .now), (1.04, .now)])
        expect(starts.count == 2 && abs(starts[1] - (1 + LookSchedule.gap)) < 0.001, "events just after a look wait for the gap", "\(starts)")

        // A window opening during a drag still shows at once.
        starts = play([(1, .movement), (1.1, .window), (1.2, .movement)])
        expect(starts.first == 1.1, "a window event isn't held back by a drag", "\(starts)")

        // Nothing happening: nothing looked at.
        expect(play([]).isEmpty, "no events, no looks")

        // How often the timer looks.
        expect(LookSchedule.interval(events: true, launching: false) == LookSchedule.safetyNet, "events: the timer is a safety net")
        expect(LookSchedule.interval(events: false, launching: false) == LookSchedule.poll, "no Accessibility: once a second")
        expect(LookSchedule.interval(events: true, launching: true) == LookSchedule.poll, "an app launching: once a second")

        print(failures == 0 ? "ok: \(passed) checks" : "\(failures) of \(passed + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
