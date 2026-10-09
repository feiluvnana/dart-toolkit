/// # Core
///
/// What every other module stands on: `Task`, `Batch` and `parallelize`, `Status`, `Work`,
/// `Retry`, `Cancel`, `Clock`, `Store` and `Key`, `Secret`, `Env`, `Io` and the units. No
/// dependencies.
///
/// {@category Utilities}
library;

export 'src/core.dart'
    hide
        CancelInternals,
        ClockInternals,
        CoerceBridge,
        Deadline,
        DetachableBridge,
        FileBridge,
        IoBridge,
        ProcessBridge,
        RetryInternals,
        StatusInternals,
        StoreInternals,
        TaskInternals,
        TextBridge,
        TimeoutBridge;
