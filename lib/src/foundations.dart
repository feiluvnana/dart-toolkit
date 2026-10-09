/// Not API: what a topic built on core's foundations re-exports, in place of `core.dart`: every
/// public name of `base.dart`, its bridges hidden.
library;

export 'base.dart'
    hide
        BatchInternals,
        CancelInternals,
        ClockInternals,
        CoerceBridge,
        Deadline,
        FileBridge,
        IsolateBridge,
        ProcessBridge,
        RetryInternals,
        StatusInternals,
        TaskInternals,
        TimeoutBridge;
