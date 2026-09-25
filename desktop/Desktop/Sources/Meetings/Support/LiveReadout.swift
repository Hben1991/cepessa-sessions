import Combine

/// A value with a publisher that does not invalidate views observing its owner.
///
/// For readouts that change many times a second while recording: audio levels
/// and the timer. Their few subscribers listen to `$value`; a window that
/// observes the whole model is not redrawn on every tick. (As `@Published`
/// they redrew the open reader about 12 times a second.) Unlike `@Published`,
/// `$value` delivers after the value is stored.
@propertyWrapper
struct LiveReadout<Value> {
  private let subject: CurrentValueSubject<Value, Never>

  init(wrappedValue: Value) {
    subject = CurrentValueSubject(wrappedValue)
  }

  var wrappedValue: Value {
    get { subject.value }
    nonmutating set { subject.send(newValue) }
  }

  var projectedValue: AnyPublisher<Value, Never> {
    subject.eraseToAnyPublisher()
  }
}
