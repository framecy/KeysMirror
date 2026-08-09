import Foundation

/// `MainActor.assumeIsolated` 的替身，行为相同但**不碰 Swift 并发运行时**。
///
/// 为什么不能用 `MainActor.assumeIsolated`：
/// 它内部会做 `swift_task_isCurrentExecutor(swift_task_getMainExecutor())`。
/// 在 macOS 26/27 上，编译器（Xcode 26.4 / Swift 6.4）内联进 app 的这段 stdlib 代码
/// 用的是新的 SerialExecutorRef 编码——main executor 的 identity 是**带标记位的值**
/// （实测拿到 0x40），而系统里那份 libswift_Concurrency 的 `swift_task_isMainExecutorImpl`
/// 仍把它当裸 `HeapObject*`，直接丢进 `swift_getObjectType` 解引用 → EXC_BAD_ACCESS。
/// 编译器和系统运行时的 ABI 对不上，app 侧改不了，只能绕开。
/// （1.6.7 崩在编译器插的隔离检查上，1.7.0 崩在 assumeIsolated 上，同一个根因。）
///
/// 断言换成 `Thread.isMainThread`：语义等价（MainActor 的执行器就是主线程），
/// 走的是 pthread，跟并发运行时无关。本工程所有调用点都是挂在 `CFRunLoopGetMain()`
/// 上的 run loop source / 主线程回调，本来就满足。
///
/// 与 `assumeIsolated` 的差别：不要求 `T: Sendable`（值根本没跨隔离域，
/// 那个约束只是 stdlib 签名的保守写法）。
@inline(__always)
func assumingMainActor<T>(
    _ operation: @MainActor () throws -> T,
    file: StaticString = #fileID,
    line: UInt = #line
) rethrows -> T {
    precondition(
        Thread.isMainThread,
        "assumingMainActor 在非主线程被调用",
        file: file,
        line: line
    )
    // `@MainActor` 不参与同步函数的运行期表示，两种类型的布局完全一致。
    // 这一步和 stdlib 里 assumeIsolated 通过检查之后做的事情逐字相同。
    return try withoutActuallyEscaping(operation) { (fn: @escaping @MainActor () throws -> T) throws -> T in
        let raw = unsafeBitCast(fn, to: (() throws -> T).self)
        return try raw()
    }
}
