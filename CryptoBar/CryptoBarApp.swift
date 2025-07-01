import SwiftUI
import Combine
import AppKit
import UserNotifications

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
    @State private var showingSettings = false
    @StateObject private var appSettings = AppSettings()
    @State private var selectedCoinForDetail: Coin? = nil // 用于显示详细信息

    var body: some View {
        if showingSettings {
            SettingsView(
                settings: appSettings,
                onTest: { viewModel.sendTestNotification() },
                onDone: { showingSettings = false }
            )
        } else if let coin = selectedCoinForDetail {
            CoinDetailView(coin: coin, onBack: { selectedCoinForDetail = nil })
        } else {
            VStack(spacing: 0) {
                HeaderView(viewModel: viewModel, onSettingsTapped: { showingSettings = true })
                    .padding()

                if viewModel.connectionState == .disconnected {
                    VStack(spacing: 4) {
                        Image(systemName: "wifi.slash")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("网络连接已断开")
                            .font(.footnote)
                            .fontWeight(.semibold)
                        Text("正在自动重新连接...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.yellow.opacity(0.25))
                    .transition(.opacity.animation(.easeInOut))
                }
                
                Divider()
                
                CoinListView(viewModel: viewModel, onShowDetail: { coin in
                    selectedCoinForDetail = coin
                    // 异步获取详细信息
                    Task {
                        await viewModel.fetchCoinDetails(symbol: coin.symbol)
                    }
                })
                
                Divider()

                AddCoinView(newPair: $newPair, viewModel: viewModel)
                    .padding()
                
                FooterView(viewModel: viewModel)
                    .padding([.horizontal, .bottom])
            }
            .frame(width: 320)
            .background(.ultraThinMaterial)
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
    private let appSettings = AppSettings()
    
    // 新增: 用于 API 请求的 URLSession
    private let session = URLSession.shared

    init() {
        print("[诊断] 视图模型: 开始初始化。")
        
        webSocketService.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        loadCoins()
        
        webSocketService.priceUpdatePublisher
            .throttle(for: 1.0, scheduler: RunLoop.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (priceData: OKXResponse.TickerData) in
                self?.updateCoinPrice(priceData: priceData)
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
        let s = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // 如果用户只输入了基础货币 (例如 "BTC")，则自动添加 "-USDT"
        if !s.contains("-") {
            return "\(s)-USDT"
        }
        // 如果用户输入了完整的交易对，则直接使用
        return s
    }

    // 新增: 验证币对是否存在的函数
    private func verifySymbolExists(symbol: String) async -> Bool {
        guard let url = URL(string: "https://www.okx.com/api/v5/public/instruments?instType=SPOT&instId=\(symbol)") else {
            print("[错误] 验证 API: URL 创建失败。")
            return false
        }
        
        print("[诊断] 验证 API: 正在查询: \(url.absoluteString)")
        
        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[错误] 验证 API: HTTP 请求失败。")
                return false
            }
            
            // 我们只需要检查 'data' 数组是否为空
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                print("[诊断] 验证 API: 查询成功，找到 \(dataArray.count) 个结果。")
                return !dataArray.isEmpty
            }
        } catch {
            print("[错误] 验证 API: 请求失败 - \(error.localizedDescription)")
        }
        
        return false
    }

    // 修改: addCoin 函数现在是异步的
    func addCoin(symbol: String) async -> (success: Bool, message: String) {
        let okxSymbol = formatSymbolForOKX(symbol)
        
        guard !coins.contains(where: { $0.symbol.uppercased() == okxSymbol.uppercased() }) else {
            let msg = "币对 '\(okxSymbol)' 已经存在。"
            return (false, msg)
        }
        
        // 在添加前进行 API 验证
        let exists = await verifySymbolExists(symbol: okxSymbol)
        guard exists else {
            let msg = "币对 '\(okxSymbol)' 在 OKX 交易所不存在或无效。"
            return (false, msg)
        }
        
        print("[诊断] 视图模型: 正在添加币对 (OKX 格式): \(okxSymbol)")
        
        // 由于函数是异步的，确保 UI 更新在主线程上执行
        await MainActor.run {
            let newCoin = Coin(symbol: okxSymbol)
            coins.append(newCoin)
            
            if selectedCoinSymbol == nil {
                selectCoin(coin: newCoin)
            }
            
            webSocketService.subscribe(to: okxSymbol)
        }
        
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
    
    private func updateCoinPrice(priceData: OKXResponse.TickerData) {
        guard let index = coins.firstIndex(where: { $0.symbol.uppercased() == priceData.instId.uppercased() }) else { return }
        
        let price = priceData.last // 使用 priceData.last
        if coins[index].price != price {
            coins[index].price = price
            
            // 新增: 更新价格历史并检查波动
            if let priceDouble = Double(price) {
                updatePriceHistory(for: &coins[index], newPrice: priceDouble)
            }
        }
        
        // 新增: 更新详细信息
        coins[index].high24h = priceData.high24h
        coins[index].low24h = priceData.low24h
        coins[index].vol24h = priceData.vol24h
        coins[index].volCcy24h = priceData.volCcy24h
        coins[index].sodUtc0 = priceData.sodUtc0
        coins[index].sodUtc8 = priceData.sodUtc8
        
        // 计算并格式化24小时涨跌幅
        if let currentPrice = Double(price), let openPrice = Double(priceData.open24h), openPrice != 0 {
            let change = ((currentPrice - openPrice) / openPrice) * 100
            let sign = change >= 0 ? "+" : ""
            coins[index].change24h = String(format: "%@%.2f%%", sign, change)
        } else {
            coins[index].change24h = nil
        }
        
        if priceData.instId == selectedCoinSymbol {
            updateMenuBarPrice(coins: self.coins)
        }
    }
    
    // 新增: 从 REST API 获取单个币对的详细信息
    func fetchCoinDetails(symbol: String) async -> Coin? {
        let okxSymbol = formatSymbolForOKX(symbol)
        guard let url = URL(string: "https://www.okx.com/api/v5/market/index-tickers?instId=\(okxSymbol)") else {
            print("[错误] 详细信息 API: URL 创建失败。")
            return nil
        }
        
        print("[诊断] 详细信息 API: 正在查询: \(url.absoluteString)")
        
        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[错误] 详细信息 API: HTTP 请求失败。")
                return nil
            }
            
            let decoder = JSONDecoder()
            if let response = try? decoder.decode(OKXResponse.self, from: data), let tickerData = response.data?.first {
                // 找到对应的 Coin 对象并更新其详细信息
                if let index = coins.firstIndex(where: { $0.symbol.uppercased() == tickerData.instId.uppercased() }) {
                    await MainActor.run {
                        // 使用 idxPx 更新 price
                        if let idxPx = tickerData.idxPx {
                            coins[index].price = idxPx
                        }
                        coins[index].high24h = tickerData.high24h
                        coins[index].low24h = tickerData.low24h
                        coins[index].vol24h = tickerData.vol24h
                        coins[index].volCcy24h = tickerData.volCcy24h
                        coins[index].sodUtc0 = tickerData.sodUtc0
                        coins[index].sodUtc8 = tickerData.sodUtc8
                        // 价格和24h涨跌幅已经在 WebSocket 更新时处理
                    }
                    return coins[index]
                }
            }
        } catch {
            print("[错误] 详细信息 API: 请求失败 - \(error.localizedDescription)")
        }
        
        return nil
    }
    
    // 新增: 更新价格历史记录并检查波动
    private func updatePriceHistory(for coin: inout Coin, newPrice: Double) {
        let now = Date()
        
        // 1. 添加新价格记录
        coin.priceHistory.append((date: now, price: newPrice))
        
        // 2. 清理旧记录 (使用设置中的时间窗口)
        let timeWindow = TimeInterval(appSettings.alertTimeWindow * 60)
        let historyStartDate = now.addingTimeInterval(-timeWindow)
        coin.priceHistory.removeAll { $0.date < historyStartDate }
        
        // 3. 检查波动 (如果距离上次提醒超过时间窗口)
        if appSettings.notificationsEnabled,
           (coin.lastAlertDate == nil || now.timeIntervalSince(coin.lastAlertDate!) > timeWindow) {
            checkForPriceSpike(for: &coin)
        }
    }

    // 新增: 检查价格剧烈波动
    private func checkForPriceSpike(for coin: inout Coin) {
        guard coin.priceHistory.count > 1 else { return }
        
        let recentHistory = coin.priceHistory
        
        guard let firstPrice = recentHistory.first?.price,
              let lastPrice = recentHistory.last?.price else { return }
        
        let percentageChange = ((lastPrice - firstPrice) / firstPrice) * 100
        
        // 检查价格上涨或下跌是否超过设定的阈值
        if abs(percentageChange) >= appSettings.alertThreshold {
            let direction = percentageChange > 0 ? "上涨" : "下跌"
            let message = "\(coin.symbol) 在过去\(appSettings.alertTimeWindow)分钟内价格\(direction)\(String(format: "%.2f", abs(percentageChange)))%。当前价格: $\(lastPrice)"
            
            sendNotification(title: "价格提醒", body: message)
            
            // 更新上次提醒时间，避免频繁提醒
            coin.lastAlertDate = Date()
        }
    }

    // 新增: 发送用户通知
    func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[错误] 通知授权请求失败: \(error.localizedDescription)")
                return
            }
            
            guard granted else {
                print("[信息] 用户未授权发送通知。")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error = error {
                    print("[错误] 添加通知请求失败: \(error.localizedDescription)")
                } else {
                    print("[诊断] 通知已成功发送: \(title) - \(body)")
                }
            }
        }
    }

    // 新增: 发送测试通知
    func sendTestNotification() {
        sendNotification(title: "涨跌报警测试", body: "这是一条测试通知。如果您能看到它，说明通知功能工作正常。")
    }
    
    private func updateMenuBarPrice(coins: [Coin]) {
        let newMenuBarPrice: String

        if connectionState == .disconnected {
            newMenuBarPrice = "..."
        } else if let selectedSymbol = selectedCoinSymbol,
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
    
    let priceUpdatePublisher = PassthroughSubject<OKXResponse.TickerData, Never>()
    
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
                self.disconnect(isReconnecting: true)
            }
        }
    }
    
    private func handle(message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        if text == "pong" { print("[诊断] WebSocket: receive - 收到 pong 响应。"); return }
        guard let data = text.data(using: .utf8) else { return }
        do {
            if let response = try? JSONDecoder().decode(OKXResponse.self, from: data), let priceData = response.data?.first {
                priceUpdatePublisher.send(priceData)
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
    var change24h: String? = nil // 24小时涨跌幅

    // 新增: 用于价格波动报警
    var priceHistory: [(date: Date, price: Double)] = []
    var lastAlertDate: Date?

    // 新增: 存储更详细的市场数据
    var high24h: String?      // 24小时最高价
    var low24h: String?       // 24小时最低价
    var vol24h: String?       // 24小时成交量 (币)
    var volCcy24h: String?    // 24小时成交量 (计价货币, e.g., USDT)
    var sodUtc0: String?      // UTC+0 时区的开盘价
    var sodUtc8: String?      // UTC+8 时区的开盘价

    static func == (lhs: Coin, rhs: Coin) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
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
        let last: String // 价格字段改回 last，以匹配 WebSocket 数据
        let open24h: String // 24小时开盘价
        let high24h: String? // 24小时最高价
        let low24h: String?  // 24小时最低价
        let vol24h: String?  // 24小时成交量 (币)
        let volCcy24h: String? // 24小时成交量 (计价货币, e.g., USDT)
        let sodUtc0: String? // UTC+0 时区的开盘价
        let sodUtc8: String? // UTC+8 时区的开盘价
        let idxPx: String? // 新增：用于解析 index-tickers API 的 idxPx 字段
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

extension NumberFormatter {
    static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    static let largeNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0 // 默认不显示小数
        return formatter
    }()
}

// =================================================================================
// MARK: - 应用设置
// =================================================================================

class AppSettings: ObservableObject {
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("alertThreshold") var alertThreshold: Double = 1.0 // 百分比
    @AppStorage("alertTimeWindow") var alertTimeWindow: Int = 5 // 分钟
}

// MARK: - 子视图完整实现
struct HeaderView: View {
    @ObservedObject var viewModel: CoinListViewModel
    var onSettingsTapped: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("CryptoBar")
                .font(.headline)
                .fontWeight(.bold)

            Spacer()
            
            Button(action: onSettingsTapped) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")

            Button(action: {
                viewModel.refreshConnection()
            }) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新连接")
        }
    }
}

struct CoinListView: View {
    @ObservedObject var viewModel: CoinListViewModel
    var onShowDetail: (Coin) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if viewModel.coins.isEmpty {
                    VStack {
                        Image(systemName: "tray.fill")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                        Text("列表为空")
                            .font(.headline)
                        Text("请添加一个币对开始追踪")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(height: 200)
                } else {
                    ForEach(viewModel.coins) { coin in
                        CoinRowView(coin: coin, viewModel: viewModel, onShowDetail: onShowDetail)
                        Divider().padding(.leading, 50) // 在行之间添加分隔线
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 250)
    }
}

struct CoinRowView: View {
    let coin: Coin
    @ObservedObject var viewModel: CoinListViewModel
    var onShowDetail: (Coin) -> Void // 新增：显示详细信息的闭包

    var body: some View {
        HStack(spacing: 12) {
            // 左侧：币对信息和价格，点击选择币对
            Button(action: {
                viewModel.selectCoin(coin: coin)
            }) {
                HStack {
                    // Icon and text
                    Image(systemName: "bitcoinsign.circle.fill")
                        .font(.title)
                        .foregroundColor(.primary.opacity(0.8))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coin.symbol.replacingOccurrences(of: "-USDT", with: ""))
                            .fontWeight(.semibold)
                        Text("OKX")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Price and change
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(coin.price == "..." ? "..." : "$\(coin.price)")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        
                        if let change = coin.change24h {
                            Text(change)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(change.hasPrefix("+") ? .green : (change.hasPrefix("-") ? .red : .secondary))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 新增：信息按钮，点击显示详细信息
            Button(action: {
                onShowDetail(coin)
            }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("查看\(coin.symbol)详细信息")

            // 删除按钮
            Button(action: {
                viewModel.deleteCoin(coin: coin)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(0.5))
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("删除\(coin.symbol)")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(viewModel.selectedCoinSymbol == coin.symbol ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedCoinSymbol)
    }
}


struct AddCoinView: View {
    @Binding var newPair: String
    @ObservedObject var viewModel: CoinListViewModel
    
    // 状态管理
    @State private var isAdding = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("添加币对 (例如: BTC)", text: $newPair)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(8)
                    .onSubmit(addCoin)
                    .disabled(isAdding)
                    .onChange(of: newPair) { _, _ in
                        // 用户开始输入时，清除错误信息
                        if errorMessage != nil {
                            errorMessage = nil
                        }
                    }

                Button(action: addCoin) {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("添加")
                .disabled(isAdding || newPair.isEmpty)
            }
            
            // 内联错误信息显示
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .transition(.opacity.animation(.easeInOut))
            }
        }
    }
    
    private func addCoin() {
        let pair = newPair.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pair.isEmpty, !isAdding else { return }

        isAdding = true
        errorMessage = nil // 开始添加时清除旧错误
        
        Task {
            let result = await viewModel.addCoin(symbol: pair)
            
            await MainActor.run {
                if !result.success {
                    errorMessage = result.message
                } else {
                    newPair = "" // 成功后才清空输入框
                }
                isAdding = false
            }
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

// =================================================================================
// MARK: - 设置视图
// =================================================================================

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onTest: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("设置")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 10)

            // Enable/Disable Toggle
            Toggle(isOn: $settings.notificationsEnabled) {
                Text("启用价格提醒")
                    .font(.headline)
            }
            .padding(.horizontal)

            if settings.notificationsEnabled {
                // Alert Parameters Section (custom layout, not Form Section)
                VStack(alignment: .leading, spacing: 15) {
                    Text("提醒参数")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.leading) // Indent title

                    // Volatility Threshold
                    HStack {
                        Text("波动阈值:")
                        Spacer()
                        Stepper(value: $settings.alertThreshold, in: 0.1...10.0, step: 0.1) {
                            Text(String(format: "%.1f%%", settings.alertThreshold))
                        }
                    }
                    .padding(.horizontal)

                    // Time Window
                    HStack {
                        Text("时间窗口:")
                        Spacer()
                        Stepper(value: $settings.alertTimeWindow, in: 1...60) {
                            Text("\(settings.alertTimeWindow) 分钟")
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.1)) // Subtle background
                .cornerRadius(8) // Rounded corners for the section
                .padding(.horizontal) // Padding to separate from edges
            }
            
            Spacer() // Pushes content to top

            // Buttons
            HStack {
                Spacer()
                Button("测试提醒", action: onTest)
                Button("完成", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding(.vertical) // Overall vertical padding
        .frame(width: 350)
    }
}

// =================================================================================
// MARK: - 币对详细信息视图
// =================================================================================

struct CoinDetailView: View {
    let coin: Coin
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("返回")

                Spacer()

                Text("\(coin.symbol.replacingOccurrences(of: "-USDT", with: "")) 详情")
                    .font(.headline)
                    .fontWeight(.bold)

                Spacer()
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    // Current Price & 24h Change
                    VStack(alignment: .leading, spacing: 5) {
                        Text(coin.price == "..." ? "..." : NumberFormatter.currencyFormatter.string(from: NSNumber(value: Double(coin.price) ?? 0)) ?? "...")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)

                        if let change = coin.change24h {
                            Text(change)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(change.hasPrefix("+") ? .green : (change.hasPrefix("-") ? .red : .secondary))
                        }
                    }
                    .padding(.vertical, 10)

                    // High/Low
                    HStack {
                        if let high = coin.high24h, let highDouble = Double(high) {
                            VStack(alignment: .leading) {
                                Text("24小时最高")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(NumberFormatter.currencyFormatter.string(from: NSNumber(value: highDouble)) ?? "...")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        }
                        Spacer()
                        if let low = coin.low24h, let lowDouble = Double(low) {
                            VStack(alignment: .trailing) {
                                Text("24小时最低")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(NumberFormatter.currencyFormatter.string(from: NSNumber(value: lowDouble)) ?? "...")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .padding(.vertical, 5)

                    Divider()

                    // Volume
                    VStack(alignment: .leading, spacing: 8) {
                        Text("成交量")
                            .font(.headline)
                            .foregroundColor(.primary)

                        if let vol = coin.vol24h, let volDouble = Double(vol) {
                            DetailRow(label: "24小时成交量 (币)", value: NumberFormatter.largeNumberFormatter.string(from: NSNumber(value: volDouble)) ?? "...")
                        }
                        if let volCcy = coin.volCcy24h, let volCcyDouble = Double(volCcy) {
                            DetailRow(label: "24小时成交额 (USDT)", value: NumberFormatter.largeNumberFormatter.string(from: NSNumber(value: volCcyDouble)) ?? "...")
                        }
                    }
                    .padding(.vertical, 5)

                    Divider()

                    // Open Prices
                    VStack(alignment: .leading, spacing: 8) {
                        Text("开盘价")
                            .font(.headline)
                            .foregroundColor(.primary)

                        if let sodUtc0 = coin.sodUtc0, let sodUtc0Double = Double(sodUtc0) {
                            DetailRow(label: "UTC+0", value: NumberFormatter.currencyFormatter.string(from: NSNumber(value: sodUtc0Double)) ?? "...")
                        }
                        if let sodUtc8 = coin.sodUtc8, let sodUtc8Double = Double(sodUtc8) {
                            DetailRow(label: "UTC+8", value: NumberFormatter.currencyFormatter.string(from: NSNumber(value: sodUtc8Double)) ?? "...")
                        }
                    }
                    .padding(.vertical, 5)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(width: 320, height: 400) // 调整尺寸以适应更多信息和新布局
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .fontWeight(.medium)
        }
    }
}