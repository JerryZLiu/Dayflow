//
//  ProcessCPUMonitor.swift
//  Dayflow
//

import Darwin.Mach
import Foundation

final class ProcessCPUMonitor {
  struct HeartbeatSnapshot {
    let currentCPUPercent: Double
    let averageCPUPercent: Double
    let peakCPUPercent: Double
    let sampleCount: Int
    let samplerInterval: TimeInterval
  }

  static let shared = ProcessCPUMonitor()

  private enum Constants {
    static let sampleInterval: TimeInterval = 30
    static let spikeThresholdPercent: Double = 150
    static let spikeThrottleInterval: TimeInterval = 15 * 60
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.dayflow.app.cpu-monitor", qos: .utility)

  private var timer: DispatchSourceTimer?
  private var currentCPUPercent: Double = 0
  private var rollingCPUPercentTotal: Double = 0
  private var rollingPeakCPUPercent: Double = 0
  private var rollingSampleCount = 0

  private init() {}

  func start() {
    let timer = lock.withLock { () -> DispatchSourceTimer? in
      guard self.timer == nil else { return nil }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      self.timer = timer
      return timer
    }

    guard let timer else { return }

    let interval = DispatchTimeInterval.seconds(Int(Constants.sampleInterval))
    timer.schedule(
      deadline: .now() + interval,
      repeating: interval
    )
    timer.setEventHandler { [weak self] in
      self?.captureSample()
    }
    timer.resume()

    queue.async { [weak self] in
      self?.captureSample()
    }
  }

  func stop() {
    let timer = lock.withLock { () -> DispatchSourceTimer? in
      let timer = self.timer
      self.timer = nil
      currentCPUPercent = 0
      rollingCPUPercentTotal = 0
      rollingPeakCPUPercent = 0
      rollingSampleCount = 0
      return timer
    }

    timer?.setEventHandler {}
    timer?.cancel()
  }

  func heartbeatSnapshotAndReset() -> HeartbeatSnapshot? {
    lock.withLock {
      guard rollingSampleCount > 0 else { return nil }

      let snapshot = HeartbeatSnapshot(
        currentCPUPercent: currentCPUPercent,
        averageCPUPercent: rollingCPUPercentTotal / Double(rollingSampleCount),
        peakCPUPercent: rollingPeakCPUPercent,
        sampleCount: rollingSampleCount,
        samplerInterval: Constants.sampleInterval
      )

      rollingCPUPercentTotal = 0
      rollingPeakCPUPercent = 0
      rollingSampleCount = 0

      return snapshot
    }
  }

  private func captureSample() {
    guard let cpuPercent = sampleProcessCPUPercent() else { return }

    let rollingPeak = lock.withLock { () -> Double in
      currentCPUPercent = cpuPercent
      rollingCPUPercentTotal += cpuPercent
      rollingPeakCPUPercent = max(rollingPeakCPUPercent, cpuPercent)
      rollingSampleCount += 1
      return rollingPeakCPUPercent
    }

    guard cpuPercent >= Constants.spikeThresholdPercent, AnalyticsService.shared.isOptedIn else {
      return
    }

    AnalyticsService.shared.throttled("app_cpu_spike", minInterval: Constants.spikeThrottleInterval)
    {
      AnalyticsService.shared.capture(
        "app_cpu_spike",
        [
          "cpu_current_pct_bucket": AnalyticsService.shared.cpuPercentBucket(cpuPercent),
          "cpu_hour_peak_pct_bucket": AnalyticsService.shared.cpuPercentBucket(rollingPeak),
          "cpu_threshold_pct": Constants.spikeThresholdPercent,
          "cpu_sampler_interval_s": Int(Constants.sampleInterval),
        ])
    }
  }

  private func sampleProcessCPUPercent() -> Double? {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0

    let result = task_threads(mach_task_self_, &threadList, &threadCount)
    guard result == KERN_SUCCESS, let threadList else { return nil }

    defer {
      let byteCount = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
      vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), byteCount)
    }

    var totalCPUPercent: Double = 0

    for index in 0..<Int(threadCount) {
      var threadInfo = thread_basic_info_data_t()
      var threadInfoCount = mach_msg_type_number_t(
        MemoryLayout.size(ofValue: threadInfo) / MemoryLayout<integer_t>.size
      )

      let infoResult = withUnsafeMutablePointer(to: &threadInfo) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { rebound in
          thread_info(
            threadList[index],
            thread_flavor_t(THREAD_BASIC_INFO),
            rebound,
            &threadInfoCount
          )
        }
      }

      guard infoResult == KERN_SUCCESS else { continue }
      guard (threadInfo.flags & TH_FLAGS_IDLE) == 0 else { continue }

      totalCPUPercent += Double(threadInfo.cpu_usage) * 100 / Double(TH_USAGE_SCALE)
    }

    return totalCPUPercent
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
