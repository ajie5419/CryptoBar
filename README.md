# CryptoBar

CryptoBar is a lightweight macOS menu bar application designed to provide real-time cryptocurrency price tracking. Built with modern Apple technologies, it offers a clean interface and essential features for staying updated on your favorite crypto assets.

## Features

-   **Real-time Price Updates**: Fetches live cryptocurrency prices from OKX exchange via WebSocket, ensuring minimal latency.
-   **Customizable Coin List**: Easily add or remove cryptocurrency pairs (e.g., BTC-USDT, ETH-USDT) to track.
-   **24-Hour Price Change**: Displays the percentage change of each tracked coin over the last 24 hours, with intuitive green/red color coding for gains/losses.
-   **Robust Input Validation**: New coin pairs are validated against the OKX exchange's official API to ensure they exist before being added.
-   **Network Status Feedback**: Provides clear visual cues in the UI and menu bar when the WebSocket connection is disconnected, along with automatic reconnection attempts.
-   **Persistent Configuration**: Your tracked coin list and selected display coin are saved across app launches.
-   **Modern UI**: Built with SwiftUI, offering a native and responsive user experience.

## Technologies Used

-   **Swift**: The primary programming language.
-   **SwiftUI**: Apple's declarative UI framework for building native user interfaces.
-   **Combine**: Apple's framework for handling asynchronous events and reactive programming.
-   **WebSocket**: For real-time data streaming from OKX.
-   **REST API**: For initial coin pair validation.

## How to Run

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/YOUR_USERNAME/CryptoBar.git
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
