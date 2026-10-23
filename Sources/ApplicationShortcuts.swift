import AppKit
import Carbon
import ApplicationServices

extension LabController {
    func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<LabController>.fromOpaque(info).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            if id.id == 1 { owner.toggleCaptureOverlay() }
            else if id.id == 2 { owner.showActionMenu(origin: "快捷键预览 · 不计入重按") }
            return noErr
        }, 1, &eventType, ptr, &hotKeyHandler)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x46504C42, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        let menuResult = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: 0x46504C42, id: 2),
                                             GetApplicationEventTarget(), 0, &menuHotKey)
        hotKeyStatus = "handler=\(handlerResult), capture=\(result), menu=\(menuResult)"
        if result == noErr && handlerResult == noErr { addLine("快捷键已注册：⌃⌥空格呼出接收层；⌃⌥M直接预览菜单。") }
        else { addLine("快捷键注册失败（\(result)）；仍可点击预览菜单。") }
    }
}
