/*
 
 LayoutManager.swift
 
 CotEditor
 https://coteditor.com
 
 Created by nakamuxu on 2005-01-10.
 
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2016 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 https://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

import Cocoa
import CoreText

final class LayoutManager: NSLayoutManager {
    
    // MARK: Public Properties
    
    var showsInvisibles = false {
        didSet {
            let wholeRange = NSRange(location: 0, length: self.textStorage?.length ?? 0)
            if self.showsOtherInvisibles {
                // -> force recaluculate layout in order to make spaces for control characters drawing
                self.invalidateGlyphs(forCharacterRange: wholeRange, changeInLength: 0, actualCharacterRange: nil)
                self.invalidateLayout(forCharacterRange: wholeRange, actualCharacterRange: nil)
            } else {
                self.invalidateDisplay(forCharacterRange: wholeRange)
            }
        }
    }
    
    var usesAntialias = true
    
    var textFont: NSFont! {
        // keep body text font to avoid the issue where the line hight can be different by composite font
        // -> DO NOT use `self.firstTextView.font`, because it may return another font in case for example:
        //    Japansete text is input nevertheless the font that user specified dosen't support it.
        didSet {
            // cache metric values to fix line height
            if let textFont = textFont {
                self.defaultLineHeight = self.defaultLineHeight(for: textFont)
                self.defaultBaselineOffset = self.defaultBaselineOffset(for: textFont)
            }
            
            // cache width of space char for hanging indent width calculation
            self.spaceWidth = textFont.advancement(character: " ").width
            
            self.invisibleLines = self.generateInvisibleLines()
        }
    }
    
    var invisiblesColor = NSColor.disabledControlTextColor {
        didSet {
            self.invisibleLines = self.generateInvisibleLines()
        }
    }
    
    private(set) var spaceWidth: CGFloat = 0
    private(set) var defaultBaselineOffset: CGFloat = 0  // defaultBaselineOffset for textFont
    private(set) var showsOtherInvisibles = false
    
    
    // MARK: Private Properties
    
    private static let usesTextFontForInvisibles = Defaults[.usesTextFontForInvisibles]
    private static let HiraginoSansName = NSFontManager.shared().availableFonts.contains(FontName.HiraginoSans) ? FontName.HiraginoSans : FontName.HiraKakuProN
    private static let observedDefaultKeys: [DefaultKeys] = [
        .invisibleSpace,
        .invisibleTab,
        .invisibleNewLine,
        .invisibleFullwidthSpace,
        
        .showInvisibleSpace,
        .showInvisibleTab,
        .showInvisibleNewLine,
        .showInvisibleFullwidthSpace,
        ]
    
    private var defaultLineHeight: CGFloat = 1.0
    
    private var showsSpace = false
    private var showsTab = false
    private var showsNewLine = false
    private var showsFullwidthSpace = false
    
    private lazy var invisibleLines: InvisibleLines = self.generateInvisibleLines()
    private struct InvisibleLines {
        let space: CTLine
        let tab: CTLine
        let newLine: CTLine
        let fullWidthSpace: CTLine
        let verticalTab: CTLine
        let replacement: CTLine
    }
    
    private enum FontName {
        static let HiraginoSans = "HiraginoSans-W3"  // since OS X 10.11 (El Capitan)
        static let HiraKakuProN = "HiraKakuProN-W3"
    }
    
    
    
    // MARK:
    // MARK: Lifecycle
    
    override init() {
        
        super.init()
        
        self.applyDefaultInvisiblesSetting()
        
        // Since NSLayoutManager's showsControlCharacters flag is totally buggy (at least on El Capitan),
        // we stopped using it since CotEditor 2.3.3 released in 2016-01.
        // Previously, CotEditor used this flag for "Other Invisible Characters."
        // However as CotEditor draws such control-glyph-alternative-characters by itself in `drawGlyphsForGlyphRange:atPoint:`,
        // this flag is actually not so necessary as I thougth. Thus, treat carefully this.
        self.showsControlCharacters = false
        
        self.typesetter = ATSTypesetter()
        
        // observe change of defaults
        for key in type(of: self).observedDefaultKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, context: nil)
        }
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    deinit {
        for key in type(of: self).observedDefaultKeys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
        }
    }
    
    
    
    // MARK: KVO
    
    /// apply change of user setting
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if let keyPath = keyPath, type(of: self).observedDefaultKeys.map({ $0.rawValue }).contains(keyPath) {
            self.applyDefaultInvisiblesSetting()
            self.invisibleLines = self.generateInvisibleLines()
            
            if let textView = self.firstTextView {
                textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: false)
            }
        }
    }
    
    
    
    // MARK: Layout Manager Methods
    
    /// adjust rect of last empty line
    override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        
        // -> height of the extra line fragment should be the same as normal other fragments that are likewise customized in ATSTypesetter
        var fragmentRect = fragmentRect
        fragmentRect.size.height = self.lineHeight
        var usedRect = usedRect
        usedRect.size.height = self.lineHeight
        
        super.setExtraLineFragmentRect(fragmentRect, usedRect: usedRect, textContainer: container)
    }
    
    
    /// draw invisible characters
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    
        NSGraphicsContext.saveGraphicsState()
        
        // set anti-alias state on screen drawing
        if NSGraphicsContext.currentContextDrawingToScreen() {
            NSGraphicsContext.current()?.shouldAntialias = self.usesAntialias
        }
        
        // draw invisibles
        if let context = NSGraphicsContext.current()?.cgContext, self.showsInvisibles {
            
            let string = self.textStorage!.string
            let isVertical = (self.firstTextView?.layoutOrientation == .vertical)
            
            // flip coordinate if needed
            if NSGraphicsContext.current()?.isFlipped ?? false {
                context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
            }
            
            // draw invisibles glyph by glyph
            for glyphIndex in glyphsToShow.location..<glyphsToShow.max {
                let charIndex = self.characterIndexForGlyph(at: glyphIndex)
                let utf16Index = String.UTF16Index(charIndex)
                let codeUnit = string.utf16[utf16Index]
                
                let line: CTLine
                switch codeUnit {
                case " ".utf16.first!, 0x00A0:  // SPACE, NO_BREAK SPACE
                    guard self.showsSpace else { continue }
                    line = self.invisibleLines.space
                    
                case "\t".utf16.first!:  // HORIZONTAL TABULATION
                    guard self.showsTab else { continue }
                    line = self.invisibleLines.tab
                    
                case "\n".utf16.first!:
                    guard self.showsNewLine else { continue }
                    line = self.invisibleLines.newLine
                    
                case 0x3000:  // IDEOGRAPHIC SPACE a.k.a. fullwidth-space (JP)
                    guard self.showsFullwidthSpace else { continue }
                    line = self.invisibleLines.fullWidthSpace
                    
                case 0x000B:  // LINE TABULATION a.k.a. vertical tab
                    guard self.showsOtherInvisibles else { continue }  // Vertical tab belongs to the other invisibles.
                    line = self.invisibleLines.verticalTab
                    
                default:
                    guard self.showsOtherInvisibles && self.glyph(at: glyphIndex, isValidIndex: nil) == NSGlyph(NSControlGlyph) else { continue }
                    // skip the second glyph if character is a surrogate-pair
                    guard (charIndex == 0) || !(UTF16.isTrailSurrogate(codeUnit) &&
                        UTF16.isLeadSurrogate(string.utf16[string.utf16.index(before: utf16Index)])) else { continue }
                    line = self.invisibleLines.replacement
                }
                
                // calculate position to draw glyph
                let lineOrigin = self.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true).origin
                let glyphLocation = self.location(forGlyphAt: glyphIndex)
                var point = lineOrigin.offsetBy(dx: origin.x + glyphLocation.x,
                                                dy: origin.y + self.defaultBaselineOffset)
                if isVertical {
                    // [note] Probably not a good solution but better than not (2016-05-25).
                    let pathBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                    point.y += pathBounds.height / 2
                }
                
                // draw character
                context.textPosition = point
                CTLineDraw(line, context)
            }
        }
        
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        
        NSGraphicsContext.restoreGraphicsState()
    }
    
    
    /// textStorage did update
    override func textStorage(_ str: NSTextStorage, edited editedMask: NSTextStorageEditedOptions, range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        
        // invalidate wrapping line indent in editRange if needed
        if editedMask & NSTextStorageEditedOptions(1) != 0 {  // Hey Swift 3, where has NSTextStorageEditedCharacters gone...
            self.invalidateIndent(in: newCharRange)
        }
        
        super.textStorage(str, edited: editedMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }
    
    
    
    // MARK: Public Methods
    
    /// return fixed line hight to avoid having defferent line hight by composite font
    var lineHeight: CGFloat {
        
        let multiple = self.firstTextView?.defaultParagraphStyle?.lineHeightMultiple ?? 1.0
        
        return round(multiple * self.defaultLineHeight)
    }
    
    
    /// invalidate indent of wrapped lines
    func invalidateIndent(in range: NSRange) {
        
        guard Defaults[.enablesHangingIndent] else { return }
        
        guard let textStorage = self.textStorage, let textView = self.firstTextView else { return }
        
        // only on focused editor
        if let window = textView.window, !self.layoutManagerOwnsFirstResponder(in: window) { return }
        
        let lineRange = (textStorage.string as NSString).lineRange(for: range)
        
        guard lineRange.length > 0 else { return }
        
        let hangingIndent = self.spaceWidth * CGFloat(Defaults[.hangingIndentWidth])
        let regex = try! NSRegularExpression(pattern: "^[ \\t]+(?!$)")
        
        // get dummy attributes to make calculation of indent width the same as layoutManager's calculation (2016-04)
        let defaultParagraphStyle = textView.defaultParagraphStyle ?? NSParagraphStyle.default()
        let indentAttributes: [String: Any] = {
            let typingParagraphStyle = (textView.typingAttributes[NSParagraphStyleAttributeName] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            typingParagraphStyle?.headIndent = 1.0  // dummy indent value for size calculation (2016-04)
            
            var attributes: [String: Any] = [:]
            attributes[NSFontAttributeName] = self.textFont
            attributes[NSParagraphStyleAttributeName] = typingParagraphStyle
            return attributes
        }()
        
        var cache = [String: CGFloat]()
        
        // process line by line
        textStorage.beginEditing()
        (textStorage.string as NSString).enumerateSubstrings(in: lineRange, options: .byLines) { (substring: String?, substringRange, enclosingRange, stop) in
            guard let substring = substring else  { return }
            
            var indent = hangingIndent
            
            // add base indent
            let baseIndentRange = regex.rangeOfFirstMatch(in: substring, range: substring.nsRange)
            if baseIndentRange.location != NSNotFound {
                let indentString = (substring as NSString).substring(with: baseIndentRange)
                if let width = cache[indentString] {
                    indent += width
                } else {
                    let width = NSAttributedString(string: indentString, attributes: indentAttributes).size().width
                    cache[indentString] = width
                    indent += width
                }
            }
            
            // apply new indent only if needed
            let paragraphStyle = textStorage.attribute(NSParagraphStyleAttributeName, at: substringRange.location, effectiveRange: nil) as? NSParagraphStyle
            if indent != paragraphStyle?.headIndent {
                let mutableParagraphStyle = (paragraphStyle ?? defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                mutableParagraphStyle.headIndent = indent
                
                textStorage.addAttribute(NSParagraphStyleAttributeName, value: mutableParagraphStyle, range: substringRange)
            }
        }
        
        textStorage.endEditing()
    }
    
    
    
    // MARK: Private Methods
    
    /// apply invisible settings
    private func applyDefaultInvisiblesSetting() {
        
        // showInvisibles will be set from EditorViewController or PrintTextView
        self.showsSpace = Defaults[.showInvisibleSpace]
        self.showsTab = Defaults[.showInvisibleTab]
        self.showsNewLine = Defaults[.showInvisibleNewLine]
        self.showsFullwidthSpace = Defaults[.showInvisibleFullwidthSpace]
        self.showsOtherInvisibles = Defaults[.showOtherInvisibleChars]
    }
    
    
    /// cache CTLineRefs for invisible characters drawing
    private func generateInvisibleLines() -> InvisibleLines {
        
        let font: NSFont = {
            if type(of: self).usesTextFontForInvisibles {
                return self.textFont!
            } else {
                let fontSize = self.textFont?.pointSize ?? 0
                return NSFont(name: "LucidaGrande", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            }
        }()
        
        let fullWidthFont = NSFont(name: type(of: self).HiraginoSansName, size: font.pointSize) ?? font
        
        let attributes: [String: Any] = [NSForegroundColorAttributeName: self.invisiblesColor,
                                         NSFontAttributeName: font]
        let fullWidthAttributes: [String: Any] = [NSForegroundColorAttributeName: self.invisiblesColor,
                                                  NSFontAttributeName: fullWidthFont]
        
        return InvisibleLines(space:          CTLine.create(string: Invisible.userSpace, attributes: attributes),
                              tab:            CTLine.create(string: Invisible.userTab, attributes: attributes),
                              newLine:        CTLine.create(string: Invisible.userNewLine, attributes: attributes),
                              fullWidthSpace: CTLine.create(string: Invisible.userFullWidthSpace, attributes: fullWidthAttributes),
                              verticalTab:    CTLine.create(string: Invisible.verticalTab, attributes: fullWidthAttributes),
                              replacement:    CTLine.create(string: Invisible.replacement, attributes: fullWidthAttributes))
    }
    
}



// MARK:

private extension CTLine {
    
    /// convenient initializer for CTLine
    class func create(string: String, attributes: [String: Any]?) -> CTLine {
        
        let attrString = NSAttributedString(string: string, attributes: attributes)
        return CTLineCreateWithAttributedString(attrString)
    }
 }
