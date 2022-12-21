import Foundation

import Base

final class DivTimerController {
  typealias RunActions = ([DivAction]) -> Void
  typealias UpdateVariable = (DivVariableName, String) -> Void
  typealias UpdateCard = () -> Void

  enum State {
    case started
    case stopped
    case paused
  }

  private let divTimer: DivTimer
  private let timerScheduler: Scheduling
  private let timeMeasuring: TimeMeasuring
  private let runActions: RunActions
  private let updateVariable: UpdateVariable
  private let updateCard: UpdateCard
  private(set) var state: State = .stopped

  private var savedDuration: TimeInterval?
  private var savedInterval: TimeInterval?
  private var tickTimer: TimerType?
  private var endTimer: TimerType?

  init(
    divTimer: DivTimer,
    timerScheduler: Scheduling,
    timeMeasuring: TimeMeasuring,
    runActions: @escaping RunActions,
    updateVariable: @escaping UpdateVariable,
    updateCard: @escaping UpdateCard
  ) {
    self.divTimer = divTimer
    self.timerScheduler = timerScheduler
    self.timeMeasuring = timeMeasuring
    self.runActions = runActions
    self.updateVariable = updateVariable
    self.updateCard = updateCard
  }

  public func start(variables: DivVariables = [:]) {
    if state != .stopped {
      DivKitLogger.error("Timer '\(divTimer.id)' can't start because it has state '\(state)'.")
      return
    }
    let expressionResolver = ExpressionResolver(variables: variables)
    guard divTimer.parametersAreValid(expressionResolver) else {
      DivKitLogger.failure("Timer '\(divTimer.id)' is not valid.")
      return
    }
    state = .started
    savedDuration = divTimer.getDuration(expressionResolver)
    savedInterval = divTimer.getTickInterval(expressionResolver)
    setVariable(0)
    timeMeasuring.start()
    makeTickTimer()
    makeEndTimer()
  }

  public func stop() {
    if state == .stopped {
      DivKitLogger.error("Timer '\(divTimer.id)' already stopped.")
      return
    }
    state = .stopped
    invalidateTimers()
    if let endActions = divTimer.endActions {
      runActions(endActions)
    }
    updateCard()
  }

  public func pause() {
    if state != .started {
      DivKitLogger.error("Timer '\(divTimer.id)' can't pause because it has state '\(state)'.")
      return
    }
    state = .paused
    timeMeasuring.pause()
    invalidateTimers()
  }

  public func resume() {
    if state != .paused {
      DivKitLogger.error("Timer '\(divTimer.id)' can't resume because it has state '\(state)'.")
      return
    }
    state = .started
    onTick()
    makeRemainderTickTimer()
    makeEndTimer()
    timeMeasuring.resume()
  }

  public func cancel() {
    state = .stopped
    invalidateTimers()
  }

  public func reset(variables: DivVariables = [:]) {
    cancel()
    start(variables: variables)
  }

  private func makeEndTimer() {
    guard let duration = savedDuration else {
      return
    }
    endTimer = timerScheduler.makeTimer(
      delay: duration - timeMeasuring.passedInterval(),
      handler: { [weak self] in
        self?.onEnd(duration: duration)
      }
    )
  }

  private func makeRemainderTickTimer() {
    guard let tickInterval = savedInterval else {
      return
    }
    let remainder = timeMeasuring.passedInterval().truncatingRemainder(dividingBy: tickInterval)
    guard remainder > ACCURACY else {
      makeTickTimer()
      return
    }
    tickTimer = timerScheduler.makeTimer(
      delay: tickInterval - remainder,
      handler: { [weak self] in
        self?.makeTickTimer()
        self?.onTick()
      }
    )
  }

  private func makeTickTimer() {
    guard let tickInterval = savedInterval else {
      return
    }
    tickTimer = timerScheduler.makeRepeatingTimer(
      interval: tickInterval,
      handler: { [weak self] in
        self?.onTick()
      }
    )
  }

  private func onTick() {
    guard state == .started else {
      return
    }
    let passedInterval = timeMeasuring.passedInterval()
    if let duration = savedDuration, passedInterval >= duration {
      return
    }
    setVariable(passedInterval)
    if let tickActions = divTimer.tickActions {
      runActions(tickActions)
    }
    updateCard()
  }

  private func onEnd(duration: TimeInterval) {
    guard state == .started else {
      return
    }
    setVariable(duration)
    stop()
  }

  private func setVariable(_ value: TimeInterval) {
    if let variableName = divTimer.valueVariable {
      let divVariableName = DivVariableName(rawValue: variableName)
      let variableValue = String(format: "%.0f", value * 1000)
      updateVariable(divVariableName, variableValue)
    }
  }

  private func invalidateTimers() {
    tickTimer?.invalidate()
    endTimer?.invalidate()
    tickTimer = nil
    endTimer = nil
  }
}

fileprivate extension DivTimer {
  func getDuration(_ expressionResolver: ExpressionResolver) -> TimeInterval? {
    let duration = self.resolveDuration(expressionResolver)
    guard duration > 0 else {
      return nil
    }
    return TimeInterval(duration / 1000)
  }

  func getTickInterval(_ expressionResolver: ExpressionResolver) -> TimeInterval? {
    guard let divTickInterval = self.resolveTickInterval(expressionResolver) else {
      return nil
    }
    return TimeInterval(divTickInterval / 1000)
  }

  func parametersAreValid(_ expressionResolver: ExpressionResolver) -> Bool {
    let duration = self.resolveDuration(expressionResolver)
    if duration > 0 {
      return true
    }
    guard let tickInterval = self.resolveTickInterval(expressionResolver), tickInterval > 0 else {
      DivKitLogger.failure("Timer '\(self.id)' parameters is not valid: tick_interval not set")
      return false
    }
    if self.tickActions == nil && self.valueVariable == nil {
      DivKitLogger.failure("Timer '\(self.id)' parameters is not valid: set tickActions or valueVariable")
      return false
    }
    return true
  }
}

private let ACCURACY = 0.01
