import SwiftUI
import Combine
import AppKit

// =================================================================================
// MARK: - 1. 主应用入口 (现代化版本)
// =================================================================================

@main
struct CryptoTickerApp: App {
    @StateObject private var viewModel = CoinListViewModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: viewModel)
        } label: {
            Text(viewModel.menuBarPrice)
        }
        .menuBarExtraStyle(.window)
    }
}

// =================================================================================
// MARK: - 3. SwiftUI 视图
// =================================================================================

struct PopoverView: View {
    @ObservedObject var viewModel: CoinListViewModel
    @State private var newPair: String = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(viewModel: viewModel)
                .padding()
            
            Divider()
            
            CoinListView(viewModel: viewModel)
            
            Divider()

            AddCoinView(newPair: $newPair, viewModel: viewModel, showAlert: $showingAlert, alertMessage: $alertMessage)
                .padding()
            
            FooterView(viewModel: viewModel)
                .padding([.horizontal, .bottom])
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("提示"), message: Text(alertMessage), dismissButton: .default(Text("好的")))
        }
    }
}

// MARK: - 视图模型

class CoinListViewModel: ObservableObject {
    @Published var coins: [Coin] = []
    @Published var menuBarPrice: String = "..."
    @Published var selectedCoinSymbol: String?
    @Published var connectionState: WebSocketService.ConnectionState = .disconnected

    private var webSocketService = WebSocketService.shared
    private var cancellables = Set<AnyCancellable>()
    private let userDefaultsKey = "savedOKXCoinPairs"
    private let selectedCoinKey = "selectedOKXCoinSymbol"

    init() {
        print("[诊断] 视图模型: 开始初始化。")
        
        webSocketService.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        loadCoins()
        
        webSocketService.priceUpdatePublisher
            .throttle(for: 1.0, scheduler: RunLoop.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (update: (symbol: String, price: String)) in
                self?.updateCoinPrice(symbol: update.symbol, price: update.price)
            }
            .store(in: &cancellables)
        
        $coins
            .throttle(for: 0.5, scheduler: RunLoop.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedCoins in
                self?.updateMenuBarPrice(coins: updatedCoins)
                self?.saveCoins()
            }
            .store(in: &cancellables)
    }
    
    func refreshConnection() {
        print("[诊断] 视图模型: 用户请求刷新连接。")
        webSocketService.forceReconnect()
    }
    
    private func formatSymbolForOKX(_ symbol: String) -> String {
        let s = symbol.lowercased()
        if let range = s.range(of: "usdt") {
            let base = s[..<range.lowerBound]
            return "\(base.uppercased())-USDT"
        }
        return symbol.uppercased() // Fallback
    }

    func addCoin(symbol: String) -> (success: Bool, message: String) {
        let okxSymbol = formatSymbolForOKX(symbol)
        
        guard !coins.contains(where: { $0.symbol.uppercased() == okxSymbol.uppercased() }) else {
            let msg = "币对 '\(okxSymbol)' 已经存在。"
            return (false, msg)
        }
        print("[诊断] 视图模型: 正在添加币对 (OKX 格式): \(okxSymbol)")
        let newCoin = Coin(symbol: okxSymbol)
        coins.append(newCoin)
        
        if selectedCoinSymbol == nil {
            selectCoin(coin: newCoin)
        }
        
        webSocketService.subscribe(to: okxSymbol)
        return (true, "")
    }
    
    func deleteCoin(coin: Coin) {
        let symbolToRemove = coin.symbol
        let wasSelectedSymbolRemoved = selectedCoinSymbol == symbolToRemove

        coins.removeAll { $0.id == coin.id }
        
        print("[诊断] 视图模型: 正在移除币对: \(symbolToRemove)")
        webSocketService.unsubscribe(from: symbolToRemove)
        
        if wasSelectedSymbolRemoved {
            selectCoin(coin: coins.first)
        }
    }
    
    func selectCoin(coin: Coin?) {
        selectedCoinSymbol = coin?.symbol
        print("[诊断] 视图模型: 已选择币对: \(selectedCoinSymbol ?? "None")")
        updateMenuBarPrice(coins: self.coins)
    }
    
    private func updateCoinPrice(symbol: String, price: String) {
        guard let index = coins.firstIndex(where: { $0.symbol.uppercased() == symbol.uppercased() }) else { return }
        
        // ** 关键修改: 直接使用原始价格字符串，不再格式化 **
        if coins[index].price != price {
            coins[index].price = price
        }
        
        if symbol == selectedCoinSymbol {
            updateMenuBarPrice(coins: self.coins)
        }
    }
    
    private func updateMenuBarPrice(coins: [Coin]) {
        let newMenuBarPrice: String
        if let selectedSymbol = selectedCoinSymbol,
           let selectedCoin = coins.first(where: { $0.symbol == selectedSymbol }),
           selectedCoin.price != "..." {
            
            // ** 关键修改: 直接使用原始价格字符串 **
            let price = "$\(selectedCoin.price)"
            newMenuBarPrice = "\(selectedCoin.symbol.replacingOccurrences(of: "-USDT", with: "")): \(price)"
            
        } else if let firstCoin = coins.first, firstCoin.price != "..." {
            let price = "$\(firstCoin.price)"
            newMenuBarPrice = "\(firstCoin.symbol.replacingOccurrences(of: "-USDT", with: "")): \(price)"
        } else {
            newMenuBarPrice = "..."
        }
        
        if menuBarPrice != newMenuBarPrice {
            menuBarPrice = newMenuBarPrice
        }
    }
    
    func loadCoins() {
        selectedCoinSymbol = UserDefaults.standard.string(forKey: selectedCoinKey)
        
        guard let symbols = UserDefaults.standard.stringArray(forKey: userDefaultsKey) else {
            print("[诊断] 视图模型: 未找到已保存的币对。")
            return
        }
        self.coins = symbols.map { Coin(symbol: $0) }
        print("[诊断] 视图模型: 已从 UserDefaults 加载币对: \(symbols), 选中: \(selectedCoinSymbol ?? "None")")
        for symbol in symbols {
            webSocketService.subscribe(to: symbol)
        }
    }
    
    func saveCoins() {
        UserDefaults.standard.set(selectedCoinSymbol, forKey: selectedCoinKey)
        let symbols = coins.map { $0.symbol }
        UserDefaults.standard.set(symbols, forKey: userDefaultsKey)
    }
}

// =================================================================================
// MARK: - WebSocket 服务 (OKX 版本)
// =================================================================================

class WebSocketService {
    static let shared = WebSocketService()
    
    enum ConnectionState {
        case connecting, connected, disconnected
    }
    @Published var connectionState: ConnectionState = .disconnected
    
    let priceUpdatePublisher = PassthroughSubject<(symbol: String, price: String), Never>()
    
    private var task: URLSessionWebSocketTask?
    private var session = URLSession(configuration: .default)
    private var pingTimer: Timer?
    private var subscribedSymbols: Set<String> = []
    
    private init() {
        connect()
    }
    
    private func connect() {
        guard task == nil else {
            print("[诊断] WebSocket: 已在连接中，忽略新的连接请求。")
            return
        }
        connectionState = .connecting
        guard let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public") else {
            print("[诊断] WebSocket: connect - 创建 URL 失败。")
            connectionState = .disconnected
            return
        }
        print("[诊断] WebSocket: connect - 正在连接到 \(url.absoluteString)...")
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
        setupPing()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.connectionState == .connecting else { return }
            print("[诊断] WebSocket: 连接超时。正在强制重连...")
            self.forceReconnect()
        }
    }
    
    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handle(message: message)
                self.receive()
            case .failure(let error):
                print("[诊断] WebSocket: receive - 接收错误: \(error.localizedDescription)。")
                self.disconnect()
            }
        }
    }
    
    private func handle(message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        if text == "pong" { print("[诊断] WebSocket: receive - 收到 pong 响应。"); return }
        guard let data = text.data(using: .utf8) else { return }
        do {
            if let response = try? JSONDecoder().decode(OKXResponse.self, from: data), let priceData = response.data?.first {
                priceUpdatePublisher.send((symbol: priceData.instId, price: priceData.last))
            } else if let errorResponse = try? JSONDecoder().decode(OKXErrorResponse.self, from: data) {
                print("[诊断] WebSocket: handle - 收到错误响应: \(errorResponse.msg)")
            } else if let subscribeResponse = try? JSONDecoder().decode(OKXSubscribeResponse.self, from: data), subscribeResponse.event == "subscribe" {
                print("[诊断] WebSocket: handle - 成功订阅频道: \(subscribeResponse.arg.channel)")
                self.connectionState = .connected
            } else {
                // print("[诊断] WebSocket: handle - 收到未知消息: \(text)")
            }
        }
    }
    
    private func setupPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.task?.send(.string("ping")) { error in
                if let error = error {
                    print("[诊断] WebSocket: Ping 发送失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func forceReconnect() {
        print("[诊断] WebSocket: 正在强制重连...")
        disconnect(isReconnecting: true)
    }

    private func disconnect(isReconnecting: Bool = false) {
        connectionState = .disconnected
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        
        if isReconnecting {
             DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.connectAndResubscribe()
            }
        }
    }

    private func connectAndResubscribe() {
        connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, !self.subscribedSymbols.isEmpty else { return }
            print("[诊断] WebSocket: 正在重新订阅 \(self.subscribedSymbols.count) 个频道...")
            let symbolsToResubscribe = self.subscribedSymbols
            for symbol in symbolsToResubscribe {
                 let arg = OKXRequest.Arg(channel: "tickers", instId: symbol)
                 let request = OKXRequest(op: "subscribe", args: [arg])
                 self.sendRequest(request, isResubscribe: true)
            }
        }
    }
    
    func subscribe(to symbol: String) {
        subscribedSymbols.insert(symbol)
        let arg = OKXRequest.Arg(channel: "tickers", instId: symbol)
        let request = OKXRequest(op: "subscribe", args: [arg])
        sendRequest(request)
    }

    func unsubscribe(from symbol: String) {
        subscribedSymbols.remove(symbol)
        let arg = OKXRequest.Arg(channel: "tickers", instId: symbol)
        let request = OKXRequest(op: "unsubscribe", args: [arg])
        sendRequest(request)
    }

    private func sendRequest<T: Codable>(_ request: T, isResubscribe: Bool = false) {
        guard task?.state == .running else {
             print("[诊断] WebSocket: 连接未运行，无法发送请求。")
             if !isResubscribe {
                 forceReconnect()
             }
             return
        }
        do {
            let data = try JSONEncoder().encode(request)
            if let jsonString = String(data: data, encoding: .utf8) {
                print("[诊断] WebSocket: sendRequest - 正在发送: \(jsonString)")
                task?.send(.string(jsonString)) { error in
                    if let error = error {
                        print("[诊断] WebSocket: sendRequest - 发送失败: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("[诊断] WebSocket: sendRequest - JSON 编码错误: \(error)")
        }
    }
}

// =================================================================================
// MARK: - 数据模型
// =================================================================================

struct Coin: Identifiable, Hashable {
    let id = UUID()
    let symbol: String // e.g., BTC-USDT
    var price: String = "..."
}

// MARK: - OKX WebSocket 数据结构

struct OKXRequest: Codable {
    struct Arg: Codable {
        let channel: String
        let instId: String
    }
    let op: String
    let args: [Arg]
}

struct OKXResponse: Codable {
    struct TickerData: Codable {
        let instId: String
        let last: String
    }
    let arg: OKXRequest.Arg?
    let data: [TickerData]?
}

struct OKXErrorResponse: Codable {
    let event: String
    let msg: String
    let code: String
}

struct OKXSubscribeResponse: Codable {
    let event: String
    let arg: OKXRequest.Arg
}


// MARK: - 子视图完整实现
struct HeaderView: View {
    @ObservedObject var viewModel: CoinListViewModel
    
    var body: some View {
        HStack {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("加密货币追踪器")
                .font(.headline)

            Spacer()
            
            Button(action: {
                viewModel.refreshConnection()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("刷新连接")
        }
    }
}

struct CoinListView: View {
    @ObservedObject var viewModel: CoinListViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if viewModel.coins.isEmpty {
                    VStack {
                        Image(systemName: "tray.fill")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("列表为空")
                            .font(.headline)
                        Text("请添加一个币对开始追踪")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    ForEach(viewModel.coins) { coin in
                        CoinRowView(coin: coin, viewModel: viewModel)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .frame(maxHeight: 250)
    }
}

struct CoinRowView: View {
    let coin: Coin
    @ObservedObject var viewModel: CoinListViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(coin.symbol)
                    .fontWeight(.bold)
                Text("OKX")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(coin.price == "..." ? "..." : "$\(coin.price)")
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.semibold)

            Image(systemName: "chevron.right")
                .font(.body.weight(.light))
                .foregroundColor(.secondary)
                .opacity(viewModel.selectedCoinSymbol == coin.symbol ? 1 : 0)

            Button(action: {
                viewModel.deleteCoin(coin: coin)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("删除\(coin.symbol)")
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(viewModel.selectedCoinSymbol == coin.symbol ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            viewModel.selectCoin(coin: coin)
        }
        .animation(.easeInOut, value: viewModel.selectedCoinSymbol)
    }
}


struct AddCoinView: View {
    @Binding var newPair: String
    @ObservedObject var viewModel: CoinListViewModel
    @Binding var showAlert: Bool
    @Binding var alertMessage: String
    
    var body: some View {
        HStack {
            TextField("添加币对 (例如: btc-usdt)", text: $newPair)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(8)
                .onSubmit(addCoin)

            Button(action: addCoin) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("添加")
        }

    }
    
    private func addCoin() {
        let pair = newPair.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pair.isEmpty {
            let result = viewModel.addCoin(symbol: pair)
            if !result.success {
                alertMessage = result.message
                showAlert = true
            }
            newPair = ""
        }
    }
}

struct FooterView: View {
    @ObservedObject var viewModel: CoinListViewModel
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundColor(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("退出应用") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
        }
    }
    
    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connecting:
            return .yellow
        case .connected:
            return .green
        case .disconnected:
            return .red
        }
    }
    
    private var statusText: String {
        switch viewModel.connectionState {
        case .connecting:
            return "连接中..."
        case .connected:
            return "已连接"
        case .disconnected:
            return "已断开"
        }
    }
}
