import XCTest

// Shared by every test target (ADR-025 brought the first async-heavy
// suites): XCTest's assertions take synchronous autoclosures, so `XCTAssertEqual(await
// actor.value, x)` does not compile. These evaluate the expressions first.

public func XCTAssertEqualAsync<T: Equatable>(
    _ expression1: @autoclosure () async throws -> T,
    _ expression2: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let first = try await expression1()
        let second = try await expression2()
        XCTAssertEqual(first, second, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error): \(message())", file: file, line: line)
    }
}

public func XCTAssertTrueAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertTrue(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error): \(message())", file: file, line: line)
    }
}

public func XCTAssertFalseAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertFalse(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error): \(message())", file: file, line: line)
    }
}

public func XCTAssertNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNil(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error): \(message())", file: file, line: line)
    }
}

public func XCTAssertNotNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNotNil(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error): \(message())", file: file, line: line)
    }
}

public func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, message(), file: file, line: line)
}
