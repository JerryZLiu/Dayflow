import CoreML
import Foundation

/// Runs the r38 privacy model (three networks averaged, converted to Core ML) over a page's windows.
///
/// The model ships as three fixed-size Core ML models (windows of 192, 320 and 496 positions), because the
/// Neural Engine only runs fixed shapes fast. Each window is cut to its used length plus 36, the combined
/// reach of the six convolutions, which leaves every line character's output unchanged, and goes to the
/// smallest model that fits. Inputs: `chars` (16, 3, L) = token ids, segment ids and positions 0..<L;
/// `bag` (16, 256). Outputs: `sens` (16, L) = mean P(not "none"), `best` (16, L) = network 0's label pick.
final class PIIModelRunner: @unchecked Sendable {
  static let batchSize = 16
  static let convolutionReach = 36
  static let sizes = [192, 320, 496]

  private let models: [Int: MLModel]

  /// `compiledModels` maps each size to its compiled `.mlmodelc` folder.
  init(compiledModels: [Int: URL]) throws {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    var models: [Int: MLModel] = [:]
    for size in Self.sizes {
      guard let url = compiledModels[size] else {
        throw PIIModelError.missingModel(size)
      }
      models[size] = try MLModel(contentsOf: url, configuration: configuration)
    }
    self.models = models
  }

  /// Per line, per code point: the averaged sensitive score and the label pick.
  func scores(lines: [PIIOCRLine], page: PIIEncoder.Page) throws -> (
    sensitive: [[Float]], best: [[Int]]
  ) {
    var sensitive = lines.map { [Float](repeating: 0, count: $0.text.unicodeScalars.count) }
    var best = lines.map { [Int](repeating: 0, count: $0.text.unicodeScalars.count) }

    var groups: [Int: [Int]] = [:]
    for (index, example) in page.examples.enumerated() {
      let needed = min(example.usedLength + Self.convolutionReach, PIIEncoder.sequenceLength)
      let size = Self.sizes.first { $0 >= needed } ?? PIIEncoder.sequenceLength
      groups[size, default: []].append(index)
    }

    let bag = try bagArray(page.bag)
    for (size, indices) in groups.sorted(by: { $0.key < $1.key }) {
      guard let model = models[size] else { throw PIIModelError.missingModel(size) }
      for batchStart in stride(from: 0, to: indices.count, by: Self.batchSize) {
        let batch = Array(indices[batchStart..<min(batchStart + Self.batchSize, indices.count)])
        // Each prediction's outputs hold Neural Engine memory until their autorelease pool drains.
        // Without a pool per batch, about 100k predictions in, Core ML fails to allocate and
        // throws an Objective-C exception that Swift can't catch, which takes the app down.
        try autoreleasepool {
          let chars = try charsArray(batch.map { page.examples[$0] }, length: size)
          let input = try MLDictionaryFeatureProvider(dictionary: ["chars": chars, "bag": bag])
          let output = try model.prediction(from: input)
          guard let sens = output.featureValue(for: "sens")?.multiArrayValue,
            let labels = output.featureValue(for: "best")?.multiArrayValue
          else {
            throw PIIModelError.badOutput
          }
          for (row, exampleIndex) in batch.enumerated() {
            let example = page.examples[exampleIndex]
            for i in 0..<(example.end - example.start) {
              let position = example.offset + i
              if position >= size { break }
              sensitive[example.line][example.start + i] = Self.value(sens, row, position)
              best[example.line][example.start + i] = Int(Self.value(labels, row, position))
            }
          }
        }
      }
    }
    return (sensitive, best)
  }

  private func charsArray(_ examples: [PIIEncoder.Example], length: Int) throws -> MLMultiArray {
    let array = try MLMultiArray(
      shape: [NSNumber(value: Self.batchSize), 3, NSNumber(value: length)], dataType: .int32)
    let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
    let strides = array.strides.map(\.intValue)
    for row in 0..<Self.batchSize {
      for position in 0..<length {
        let base = row * strides[0] + position * strides[2]
        let example = row < examples.count ? examples[row] : nil
        pointer[base] = example?.ids[position] ?? PIIEncoder.pad
        pointer[base + strides[1]] = example?.segments[position] ?? 0
        pointer[base + 2 * strides[1]] = Int32(position)
      }
    }
    return array
  }

  private func bagArray(_ bag: [Int32]) throws -> MLMultiArray {
    let array = try MLMultiArray(
      shape: [NSNumber(value: Self.batchSize), NSNumber(value: PIIEncoder.pageWords)],
      dataType: .int32)
    let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
    let strides = array.strides.map(\.intValue)
    for row in 0..<Self.batchSize {
      for (column, id) in bag.enumerated() {
        pointer[row * strides[0] + column * strides[1]] = id
      }
    }
    return array
  }

  /// Reads `array[row, position]` whatever number type Core ML handed back.
  private static func value(_ array: MLMultiArray, _ row: Int, _ position: Int) -> Float {
    let offset = row * array.strides[0].intValue + position * array.strides[1].intValue
    switch array.dataType {
    case .float16:
      return Float(array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)[offset])
    case .float32:
      return array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)[offset]
    case .double:
      return Float(array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[offset])
    case .int32:
      return Float(array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)[offset])
    default:
      return array[[NSNumber(value: row), NSNumber(value: position)]].floatValue
    }
  }
}

enum PIIModelError: Error {
  case missingModel(Int)
  case badOutput
}
