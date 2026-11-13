import DockCore
import Foundation

extension PluginRuntime {
    /// A hook call from inside the script, on the plugin's queue: decoded, checked against the
    /// plugin's grants and limits, then handed to the main thread. Refusals become errors in
    /// the script at the call that caused them.
    func handleHook(kind: String, payload: String) -> String {
        let message: PluginHookMessage
        do { message = try PluginHookMessage.decode(kind: kind, payload: payload) } catch {
            return Self.hookError(error.description)
        }
        if let permission = message.permission, !granted.contains(permission) {
            return Self.hookError(PluginFailure.permission(permission.rawValue).description)
        }
        if let reason = hookLimits.admit(message) { return Self.hookError(reason) }
        signal(.hook(message))
        return "null"
    }

    static func hookError(_ text: String) -> String {
        JSONValue.object(["__error": .string(text)]).text()
    }

    /// A line in the plugin's Console, from Atelier's side of a hook.
    func note(_ level: String, _ text: String) { signal(.log(level: level, text: text)) }
}
