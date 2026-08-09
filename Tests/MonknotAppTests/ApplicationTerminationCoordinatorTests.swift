import XCTest
@testable import MonknotApp

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    func testAllRegisteredHandlersMustAllowTermination() async {
        let coordinator = ApplicationTerminationCoordinator()
        coordinator.register(id: UUID()) { true }
        coordinator.register(id: UUID()) { true }

        let shouldTerminate = await coordinator.resolveRegisteredHandlers()
        XCTAssertTrue(shouldTerminate)
    }

    func testOneCancellationPreventsTermination() async {
        let coordinator = ApplicationTerminationCoordinator()
        coordinator.register(id: UUID()) { true }
        coordinator.register(id: UUID()) { false }

        let shouldTerminate = await coordinator.resolveRegisteredHandlers()
        XCTAssertFalse(shouldTerminate)
    }

    func testUnregisteredWindowNoLongerBlocksTermination() async {
        let coordinator = ApplicationTerminationCoordinator()
        let handlerID = UUID()
        coordinator.register(id: handlerID) { false }
        coordinator.unregister(id: handlerID)

        let shouldTerminate = await coordinator.resolveRegisteredHandlers()
        XCTAssertTrue(shouldTerminate)
    }

    func testRegisteringTheSameWindowReplacesItsHandler() async {
        let coordinator = ApplicationTerminationCoordinator()
        let handlerID = UUID()
        coordinator.register(id: handlerID) { false }
        coordinator.register(id: handlerID) { true }

        let shouldTerminate = await coordinator.resolveRegisteredHandlers()
        XCTAssertTrue(shouldTerminate)
    }
}
