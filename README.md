# CryptoBar

CryptoBar is a lightweight macOS menu bar application designed to provide real-time cryptocurrency price tracking. Built with modern Apple technologies, it offers a clean interface and essential features for staying updated on your favorite crypto assets.

## Features

-   **实时价格更新 (Real-time Price Updates)**: 通过 WebSocket 从 OKX 交易所获取实时加密货币价格，确保低延迟。
-   **可定制币对列表 (Customizable Coin List)**: 轻松添加或移除要追踪的加密货币对（例如：BTC-USDT, ETH-USDT）。
-   **24小时价格变化 (24-Hour Price Change)**: 显示每个追踪币对在过去24小时内的百分比变化，并用直观的绿色/红色表示涨跌。
-   **币对输入验证 (Coin Pair Input Validation)**: 新增币对时，会通过 OKX 交易所的官方 API 验证其是否存在，确保数据有效性。
-   **价格波动提醒 (Price Fluctuation Alerts)**: 用户可以设置价格波动阈值和时间窗口，当币对价格在指定时间内超过设定的波动百分比时，应用会发送通知提醒。
-   **详细币对信息视图 (Detailed Coin Information View)**: 提供一个专门的视图，显示币对的24小时最高价、最低价、成交量以及UTC+0和UTC+8的开盘价等详细市场数据。
-   **网络状态反馈 (Network Status Feedback)**: 当 WebSocket 连接断开时，在 UI 和菜单栏中提供清晰的视觉提示，并自动尝试重新连接。
-   **持久化配置 (Persistent Configuration)**: 您追踪的币对列表和选定的显示币对会在应用重启后保留。
-   **现代化用户界面 (Modern UI)**: 使用 SwiftUI 构建，提供原生且响应迅速的用户体验。
-   **UI/UX 改进 (UI/UX Improvements)**:
    *   添加币对时有加载指示器和错误信息提示。
    *   币对列表中新增了查看详细信息的按钮。
    *   设置界面现在包含价格提醒的配置选项。

## Technologies Used

-   **Swift**: The primary programming language.
-   **SwiftUI**: Apple's declarative UI framework for building native user interfaces.
-   **Combine**: Apple's framework for handling asynchronous events and reactive programming.
-   **WebSocket**: For real-time data streaming from OKX.
-   **REST API**: For initial coin pair validation.

## How to Run

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/ajie5419/CryptoBar.git
    cd CryptoBar
    ```
2.  **Open in Xcode**: Open the `CryptoBar.xcodeproj` file in Xcode.
3.  **Build and Run**: Select your Mac as the target device and click the "Run" (▶) button in Xcode.

The application will appear in your macOS menu bar.

## Future Enhancements (Potential)

-   Support for multiple cryptocurrency exchanges (e.g., Binance, Coinbase).
-   Dedicated preferences window for advanced settings.
-   Customizable refresh rates and notification options.
-   More detailed coin information on tap.
## Power
-   for gemini-2.5pro
