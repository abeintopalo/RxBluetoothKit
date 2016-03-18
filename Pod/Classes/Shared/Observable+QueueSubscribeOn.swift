//
//  Observable+QueueSubscribeOn.swift
//  Pods
//
//  Created by Przemysław Lenart on 04/03/16.
//
//

import Foundation
import RxSwift


public class SerializedSubscriptionQueue {
    let scheduler: ImmediateSchedulerType
    let lock = NSLock()

    // First element on queue is curently subscribed and not completed
    // observable. All others are queued for subscription when the first
    // one is finished.
    var queue: [DelayedObservableType] = []

    /**
     Creates a queue in which subscriptions will be executed sequentially after previous ones have finished.

    - parameter scheduler: Scheduler on which subscribption will be scheduled
    */
    public init(scheduler: ImmediateSchedulerType) {
        self.scheduler = scheduler
    }

    // Queue subscription for a queue. If observable is inserted
    // into empty queue it's subscribed immediately. Otherwise
    // it waits for completion from other observables.
    func queueSubscription(observable: DelayedObservableType) {
        lock.lock(); defer { lock.unlock() }
        let execute = queue.isEmpty
        queue.append(observable)
        if execute {
            // Observable is scheduled immidiately
            queue.first?.delayedSubscribe(scheduler)
        }
    }

    func unsubscribe(observable: DelayedObservableType) {
        lock.lock(); defer { lock.unlock() }

        // Find index of observable which should be unsubscribed
        // and remove it from queue
        if let index = queue.indexOf({ $0 === observable }) {
            queue.removeAtIndex(index)
            // If first item was unsubscribed, subscribe on next one
            // if available
            if index == 0 {
                queue.first?.delayedSubscribe(scheduler)
            }
        }
    }
}

protocol DelayedObservableType: class {
    func delayedSubscribe(scheduler: ImmediateSchedulerType)
}

class QueueSubscribeOn<Element>: Cancelable, ObservableType, ObserverType, DelayedObservableType {
    typealias E = Element

    let source: Observable<Element>
    let queue: SerializedSubscriptionQueue
    var observer: AnyObserver<Element>?

    let serialDisposable = SerialDisposable()
    var isDisposed: Int32 = 0
    var disposed: Bool {
        return isDisposed == 1
    }

    init(source: Observable<Element>, queue: SerializedSubscriptionQueue) {
        self.source = source
        self.queue = queue
    }

    // All event needs to be passed to original observer
    // if subscription was not disposed. If stream is completed
    // cleanup should occur.
    func on(event: Event<Element>) {
        guard !disposed else { return }
        observer?.on(event)
        if event.isStopEvent {
            dispose()
        }
    }

    // Part of producer implementation. We need to make sure that we can optimize
    // scheduling of a work (taken from RxSwift source code)
    func subscribe<O: ObserverType where O.E == Element>(observer: O) -> Disposable {
        if !CurrentThreadScheduler.isScheduleRequired {
            return run(observer)
        } else {
            return CurrentThreadScheduler.instance.schedule(()) { _ in
                return self.run(observer)
            }
        }
    }

    // After original subscription we need to place it on queue for delayed execution if required.
    func run<O: ObserverType where O.E == Element>(observer: O) -> Disposable {
        self.observer = observer.asObserver()
        queue.queueSubscription(self)
        return self
    }

    // Delayed subscription must be called after original subscription so that observer will be stored by that time.
    func delayedSubscribe(scheduler: ImmediateSchedulerType) {
        let cancelDisposable = SingleAssignmentDisposable()
        serialDisposable.disposable = cancelDisposable
        cancelDisposable.disposable = scheduler.schedule(()) {
            self.serialDisposable.disposable = self.source.subscribe(self)
            return NopDisposable.instance
        }
    }

    // When this observable is disposed we need to remove it from queue to let other
    // observables to be able to subscribe. We are doing it on the same thread as
    // subscription.
    func dispose() {
        if OSAtomicCompareAndSwap32(0, 1, &isDisposed) {
            queue.scheduler.schedule(()) {
                self.queue.unsubscribe(self)
                self.serialDisposable.dispose()
                return NopDisposable.instance
            }
        }
    }
}

extension ObservableType {

    // swiftlint:disable missing_docs
    /**
     Store subscription in queue on which it will be executed sequentially. Subscribe method is called
     only when there are no registered subscription on queue or last running observable completed its stream
     or was disposed before that event.

     - parameter queue: Queue on which scheduled subscriptions will be executed in sequentially.
     - returns: The source which will be subscribe when queue is empty or previous observable was completed or disposed.
     */
    @warn_unused_result(message="http://git.io/rxs.uo")
    public func queueSubscribeOn(queue: SerializedSubscriptionQueue) -> Observable<E> {
        return QueueSubscribeOn(source: self.asObservable(), queue: queue).asObservable()
    }
    // swiftlint:enable missing_docs
}