import Foundation

public enum LaunchDaemonPlists {
    public static func daemon(executablePath: String) -> String {
        plist(label: "com.cjverma.anvild", executablePath: executablePath, arguments: [])
    }

    public static func watchdog(executablePath: String) -> String {
        plist(label: "com.cjverma.anvil-watchdog", executablePath: executablePath, arguments: [])
    }

    private static func plist(label: String, executablePath: String, arguments: [String]) -> String {
        let args = ([executablePath] + arguments).map { "<string>\($0)</string>" }.joined(separator: "\n        ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                \(args)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/Library/Logs/\(label).log</string>
            <key>StandardErrorPath</key>
            <string>/Library/Logs/\(label).err</string>
        </dict>
        </plist>

        """
    }
}
