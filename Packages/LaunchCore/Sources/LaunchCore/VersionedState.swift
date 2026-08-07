/// 持久化状态协议: 所有持久格式必须带 schemaVersion。
///
/// 协议位于 LaunchCore(基础层),使 LaunchPlatform 的迁移服务
/// 无需反向依赖即可处理任意状态类型。
public protocol VersionedState: Sendable {
    var schemaVersion: Int { get }
}

extension LayoutSnapshot: VersionedState {}
extension CatalogSnapshot: VersionedState {}
extension AppConfiguration: VersionedState {}
