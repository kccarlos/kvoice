import CoreML
import Foundation
import XCTest
@testable import KvoiceParakeet

/// The tensor plumbing shared by the FunASR pipelines, on hand-built
/// `MLMultiArray`s — no graph, no model. Before the 2026-09-16 split this
/// code was reachable only through a live model; the non-finite refusal,
/// the fp16 read path and the padding are now covered here.
final class CoreMLTensorSupportTests: XCTestCase {
    private func logits(_ rows: [[Float]], dataType: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: rows.count), NSNumber(value: rows[0].count)], dataType: dataType
        )
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                array[[0, NSNumber(value: r), NSNumber(value: c)]] = NSNumber(value: value)
            }
        }
        return array
    }

    func testArgmaxReadsEachValidRowAndStopsAtTheRowCount() throws {
        let array = try logits([[0.1, 0.9, 0.2], [0.7, 0.1, 0.1], [0.0, 0.0, 1.0], [5, 5, 5]])
        XCTAssertEqual(try LogitRows.argmax(array, rows: 3, model: "m", units: "u"), [1, 0, 2])
        // More rows than the tensor has is clamped, not an overrun.
        XCTAssertEqual(try LogitRows.argmax(array, rows: 10, model: "m", units: "u"), [1, 0, 2, 0])
    }

    func testFloat16StorageIsReadThroughVImage() throws {
        let array = try logits([[0.25, 0.5, 0.125], [2, 1, 0]], dataType: .float16)
        XCTAssertEqual(try LogitRows.argmax(array, rows: 2, model: "m", units: "u"), [1, 0])
        XCTAssertEqual(try LogitRows.rows(array, count: 2, width: 3, model: "m", units: "u"), [[0.25, 0.5, 0.125], [2, 1, 0]])
    }

    func testANonFiniteRowIsRefusedNamingTheModelAndTheUnits() throws {
        for value in [Float.nan, Float.infinity, -Float.infinity] {
            let array = try logits([[0.1, 0.2], [value, 0.3]])
            XCTAssertThrowsError(try LogitRows.argmax(array, rows: 2, model: "Paraformer encoder", units: "int8 under CPU only")) { error in
                XCTAssertEqual(
                    error as? CoreMLTensorError,
                    .nonFiniteOutput(model: "Paraformer encoder", units: "int8 under CPU only")
                )
                XCTAssertEqual(
                    error.localizedDescription,
                    "Paraformer encoder produced non-finite output (int8 under CPU only); this graph cannot run on these compute units"
                )
            }
            XCTAssertThrowsError(try LogitRows.rows(array, count: 2, width: 2, model: "m", units: "u"))
            // The bad row is beyond the valid count: not read, not refused.
            XCTAssertEqual(try LogitRows.argmax(array, rows: 1, model: "m", units: "u"), [1])
        }
    }

    func testZeroPaddedCopiesTheValidFramesAndZeroesTheRest() throws {
        let features = try logits([[1, 2], [3, 4], [5, 6]])
        let padded = try FeatureTensors.zeroPadded(features, frames: 2, bucket: 4, dimension: 2)
        XCTAssertEqual(padded.shape.map(\.intValue), [1, 4, 2])
        XCTAssertEqual(padded.dataType, .float32)
        let values = (0..<8).map { padded[$0].floatValue }
        XCTAssertEqual(values, [1, 2, 3, 4, 0, 0, 0, 0])
        // An fp16 feature tensor takes the boxed path to the same result.
        let half = try logits([[1, 2], [3, 4]], dataType: .float16)
        let paddedHalf = try FeatureTensors.zeroPadded(half, frames: 2, bucket: 3, dimension: 2)
        XCTAssertEqual((0..<6).map { paddedHalf[$0].floatValue }, [1, 2, 3, 4, 0, 0])
    }

    func testScalarIsAOneElementInt32Tensor() throws {
        let scalar = try FeatureTensors.scalar(14)
        XCTAssertEqual(scalar.shape.map(\.intValue), [1])
        XCTAssertEqual(scalar.dataType, .int32)
        XCTAssertEqual(scalar[0].int32Value, 14)
    }
}
