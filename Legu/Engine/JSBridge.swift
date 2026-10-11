import Foundation
import JavaScriptCore

/// 书源 JS(`@js:`)求值:JavaScriptCore + `java.ajax` 同步抓取
enum JSBridge {

    static func evaluate(_ code: String, result: String, ctx: EvalContext) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result }
        guard let context = JSContext() else { return result }
        context.exceptionHandler = { _, _ in }

        context.setObject(result, forKeyedSubscript: "result" as NSString)
        context.setObject(ctx.key, forKeyedSubscript: "key" as NSString)
        context.setObject(ctx.page, forKeyedSubscript: "page" as NSString)
        context.setObject(ctx.base, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(ctx.bookUrl, forKeyedSubscript: "bookUrl" as NSString)
        let host = JSHost()
        context.setObject(host, forKeyedSubscript: "java" as NSString)

        let value = context.evaluateScript(trimmed)
        if context.exception != nil { return result }
        if let v = value, !v.isUndefined, !v.isNull {
            if let s = v.toString() {
                return s
            }
        }
        return result
    }
}

/// 暴露给 JS 的 java 对象(目前提供同步抓取)
@objc protocol JSHostExport: JSExport {
    func ajax(_ url: String) -> String
}

final class JSHost: NSObject, JSHostExport {
    func ajax(_ url: String) -> String {
        HTTP.fetchDataSync(url)
    }
}
