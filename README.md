# DJVU Reader macOS

A modern DJVU and PDF document viewer for macOS with dual viewing modes and advanced caching.

## Features

- 📚 Support for DJVU, DJV, and PDF formats
- 🔄 Two viewing modes: page-by-page and continuous
- 🔍 Smooth zooming with position preservation
- ⚡ Intelligent caching and page preloading
- ⌨️ Full keyboard shortcuts support
- 👆 Gestures and swipes for navigation
- 🎨 Modern native macOS interface
- 🌙 Dark theme support
- 🖱️ Drag & Drop support

## Supported Formats

- 📖 **DJVU/DJV** - e-books and scanned documents
- 📄 **PDF** - portable documents (built-in support)

## 📸 Screenshots

### Main Page
<img width="630" alt="Screenshot 2025-06-05 at 17 03 22" src="https://github.com/user-attachments/assets/3927bd78-a474-4266-ba8b-71905bb2783f" />

### File Viewer
<img width="630" alt="Screenshot 2025-06-05 at 17 10 11" src="https://github.com/user-attachments/assets/3b812a40-7867-4749-8503-ecff82643e91" />

## 📥 Installing the Ready-Made Application

### Download the Ready-Made Application
1. Go to the [releases page](https://github.com/username/djvu-reader/releases)
2. Download the `DJVUReader.dmg` or `DJVUReader.zip` file from the latest version
3. Open the downloaded file and move `DJVU Reader.app` to the **Applications** folder

### ⚠️ First Launch (Important!)

macOS will show a security warning since the application is created by an independent developer. **This is normal!**

#### Correct Way to Launch for the First Time:
1. **Right-click** on `DJVU Reader.app` in the Applications folder
2. Select **"Open"** from the context menu
3. In the dialog that appears, click **"Open"**
4. The application will launch and won't show warnings anymore

#### Alternative Method:
1. Try to launch the application normally
2. A warning will appear - click **"Cancel"**
3. After dragging the application to the **"Applications"** folder, run this command in Terminal:
```bash
sudo xattr -r -c /Applications/DJVUReader.app
```
4. Open the application again

### Installing DjVuLibre for DJVU Files

To work with DJVU files, you need to install DjVuLibre via Homebrew:

```bash
brew install djvulibre
```

*Note: PDF files work without additional libraries*

## 🛠 Building from Source Code

If you want to build the application yourself:

### System Requirements for Building
- macOS 12.0 or higher
- Xcode 14.0 or higher
- Swift 5.7 or higher

### Build Instructions
1. Clone the repository:
```bash
git clone https://github.com/username/djvu-reader.git
cd djvu-reader
```

2. Open the project in Xcode:
```bash
open DJVUReader.xcodeproj
```

3. Build and run the project (⌘+R)

## Usage

### Main Functions

- **Opening Documents**: Drag a file into the window or use "File" → "Open" menu
- **Viewing Modes**: Switch between page-by-page and continuous mode
- **Zooming**: Use gestures, mouse wheel, or keyboard shortcuts
- **Navigation**: Navigate between pages with swipes, arrows, or menu

### ⌨️ Keyboard Shortcuts

#### Navigation
- `←` / `→` - Previous/next page (page-by-page mode)
- `↑` / `↓` - Previous/next page (continuous mode)
- `Space` - Next page
- `Home` - First page
- `End` - Last page

#### Zooming
- `⌘+` - Zoom in
- `⌘-` - Zoom out
- `⌘0` - Actual size

#### Viewing Modes
- `⌘1` - Page-by-page mode
- `⌘2` - Continuous mode

#### Files
- `⌘O` - Open document

### Gestures and Interaction

- **Pinch-to-zoom** - Zoom with gestures
- **Double tap** - Quick zoom
- **Panning** - Move when zoomed in
- **Swipes** - Change pages in page-by-page mode

## Architecture

The project is built using:

- **SwiftUI** - for modern user interface
- **Combine** - for reactive programming
- **PDFKit** - for working with PDF documents
- **Process/Shell** - for interaction with DjVuLibre
- **MVVM** - architectural pattern

### Project Structure

```
DJVUReader/
├── Views/
│   ├── ContentView.swift           # Main application screen
│   ├── DocumentView.swift          # Page-by-page viewer
│   ├── ContinuousDocumentView.swift # Continuous viewer
│   └── WelcomeView.swift          # Welcome screen
├── Models/
│   └── DJVUDocument.swift         # Main document model
├── App/
│   └── DJvuReaderApp.swift        # Entry point and menu
├── Utilities/
│   └── Extensions+Utilities.swift  # Helper extensions
└── Resources/
    └── Assets.xcassets            # Resources and icons
```

### Key Implementation Features

- **Asynchronous loading** of pages in background
- **Multi-level caching** (display, preload, thumbnails)
- **Russian filename handling** via temporary copies
- **Memory optimization** with automatic cache cleanup
- **Adaptive interface** for different screen sizes

## Technical Details

### DJVU File Processing
Uses DjVuLibre system utilities:
- `djvused` - for determining page count
- `ddjvu` - for converting pages to raster formats

### Caching
- **Main Cache**: High-resolution pages (scale=400-500)
- **Thumbnail Cache**: Page previews for quick navigation
- **Continuous Cache**: Special cache for continuous viewing mode
- **Auto-cleanup**: When memory limit is exceeded

### Performance
- Preloading of adjacent pages
- Background loading of entire document
- Optimized rendering with high DPI
- Smooth transition animations

## 📝 License

This project is distributed under the MIT License. Details in the `LICENSE` file.

## Author

Nikita Krivonosov - nikskrivonosovv@gmail.com
