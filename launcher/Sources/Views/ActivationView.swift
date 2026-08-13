import SwiftUI

struct ActivationView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @State private var code: String = ""
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = false
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "qrcode", withExtension: "jpg"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 60, height: 60)
                        Image(systemName: "key.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                    }
                }
                
                Text("请关注公众号，发送关键词")
                    .foregroundColor(.secondary)
                    + Text(" 激活码 ")
                        .foregroundColor(.blue)
                        .fontWeight(.medium)
                    + Text("获取激活码")
                        .foregroundColor(.secondary)
            }
            
            VStack(spacing: 16) {
                TextField("例如：AG-XXXX-XXXX", text: $code)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 280)
                    .onSubmit {
                        activate()
                    }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button(action: activate) {
                    Text(isLoading ? "验证中..." : "激活")
                        .fontWeight(.medium)
                        .frame(width: 280, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            
            Text("激活后本机无需再次输入")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(width: 400, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func activate() {
        guard !code.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        
        // 模拟一点网络延迟体验
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let result = appState.verifyActivation(code: code)
            isLoading = false
            if !result.success {
                errorMessage = result.message
            }
        }
    }
}
