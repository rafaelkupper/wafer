import Foundation

public struct ReaderThemeColor: Codable, Equatable, Sendable {
    public let hex: String
    public let alpha: Double

    public init(hex: String, alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }
}

public struct MermaidPalette: Codable, Equatable, Sendable {
    public let theme: String
    public let background: String
    public let primaryColor: String
    public let primaryTextColor: String
    public let primaryBorderColor: String
    public let lineColor: String
    public let secondaryColor: String
    public let secondaryTextColor: String
    public let tertiaryColor: String
    public let tertiaryTextColor: String
    public let mainBkg: String
    public let nodeBorder: String
    public let nodeTextColor: String
    public let titleColor: String
    public let edgeLabelBackground: String
    public let erEdgeLabelBackground: String
    public let attributeBackgroundColorOdd: String
    public let attributeBackgroundColorEven: String
    public let sectionBkgColor: String
    public let sectionBkgColor2: String
    public let altSectionBkgColor: String
    public let taskBkgColor: String
    public let taskBorderColor: String
    public let activeTaskBkgColor: String
    public let activeTaskBorderColor: String
    public let doneTaskBkgColor: String
    public let doneTaskBorderColor: String
    public let critBkgColor: String
    public let critBorderColor: String
    public let taskTextColor: String
    public let taskTextLightColor: String
    public let taskTextDarkColor: String
    public let taskTextOutsideColor: String
    public let taskTextClickableColor: String
    public let vertLineColor: String
    public let gridColor: String
    public let todayLineColor: String
    public let textColor: String
    public let fontFamily: String

    public init(
        theme: String,
        background: String,
        primaryColor: String,
        primaryTextColor: String,
        primaryBorderColor: String,
        lineColor: String,
        secondaryColor: String,
        secondaryTextColor: String,
        tertiaryColor: String,
        tertiaryTextColor: String,
        mainBkg: String,
        nodeBorder: String,
        nodeTextColor: String,
        titleColor: String,
        edgeLabelBackground: String,
        erEdgeLabelBackground: String,
        attributeBackgroundColorOdd: String,
        attributeBackgroundColorEven: String,
        sectionBkgColor: String,
        sectionBkgColor2: String,
        altSectionBkgColor: String,
        taskBkgColor: String,
        taskBorderColor: String,
        activeTaskBkgColor: String,
        activeTaskBorderColor: String,
        doneTaskBkgColor: String,
        doneTaskBorderColor: String,
        critBkgColor: String,
        critBorderColor: String,
        taskTextColor: String,
        taskTextLightColor: String,
        taskTextDarkColor: String,
        taskTextOutsideColor: String,
        taskTextClickableColor: String,
        vertLineColor: String,
        gridColor: String,
        todayLineColor: String,
        textColor: String,
        fontFamily: String
    ) {
        self.theme = theme
        self.background = background
        self.primaryColor = primaryColor
        self.primaryTextColor = primaryTextColor
        self.primaryBorderColor = primaryBorderColor
        self.lineColor = lineColor
        self.secondaryColor = secondaryColor
        self.secondaryTextColor = secondaryTextColor
        self.tertiaryColor = tertiaryColor
        self.tertiaryTextColor = tertiaryTextColor
        self.mainBkg = mainBkg
        self.nodeBorder = nodeBorder
        self.nodeTextColor = nodeTextColor
        self.titleColor = titleColor
        self.edgeLabelBackground = edgeLabelBackground
        self.erEdgeLabelBackground = erEdgeLabelBackground
        self.attributeBackgroundColorOdd = attributeBackgroundColorOdd
        self.attributeBackgroundColorEven = attributeBackgroundColorEven
        self.sectionBkgColor = sectionBkgColor
        self.sectionBkgColor2 = sectionBkgColor2
        self.altSectionBkgColor = altSectionBkgColor
        self.taskBkgColor = taskBkgColor
        self.taskBorderColor = taskBorderColor
        self.activeTaskBkgColor = activeTaskBkgColor
        self.activeTaskBorderColor = activeTaskBorderColor
        self.doneTaskBkgColor = doneTaskBkgColor
        self.doneTaskBorderColor = doneTaskBorderColor
        self.critBkgColor = critBkgColor
        self.critBorderColor = critBorderColor
        self.taskTextColor = taskTextColor
        self.taskTextLightColor = taskTextLightColor
        self.taskTextDarkColor = taskTextDarkColor
        self.taskTextOutsideColor = taskTextOutsideColor
        self.taskTextClickableColor = taskTextClickableColor
        self.vertLineColor = vertLineColor
        self.gridColor = gridColor
        self.todayLineColor = todayLineColor
        self.textColor = textColor
        self.fontFamily = fontFamily
    }

    public var themeVariables: [(key: String, value: String)] {
        [
            ("background", background),
            ("primaryColor", primaryColor),
            ("primaryTextColor", primaryTextColor),
            ("primaryBorderColor", primaryBorderColor),
            ("lineColor", lineColor),
            ("secondaryColor", secondaryColor),
            ("secondaryTextColor", secondaryTextColor),
            ("tertiaryColor", tertiaryColor),
            ("tertiaryTextColor", tertiaryTextColor),
            ("mainBkg", mainBkg),
            ("nodeBorder", nodeBorder),
            ("nodeTextColor", nodeTextColor),
            ("titleColor", titleColor),
            ("edgeLabelBackground", edgeLabelBackground),
            ("erEdgeLabelBackground", erEdgeLabelBackground),
            ("attributeBackgroundColorOdd", attributeBackgroundColorOdd),
            ("attributeBackgroundColorEven", attributeBackgroundColorEven),
            ("sectionBkgColor", sectionBkgColor),
            ("sectionBkgColor2", sectionBkgColor2),
            ("altSectionBkgColor", altSectionBkgColor),
            ("taskBkgColor", taskBkgColor),
            ("taskBorderColor", taskBorderColor),
            ("activeTaskBkgColor", activeTaskBkgColor),
            ("activeTaskBorderColor", activeTaskBorderColor),
            ("doneTaskBkgColor", doneTaskBkgColor),
            ("doneTaskBorderColor", doneTaskBorderColor),
            ("critBkgColor", critBkgColor),
            ("critBorderColor", critBorderColor),
            ("taskTextColor", taskTextColor),
            ("taskTextLightColor", taskTextLightColor),
            ("taskTextDarkColor", taskTextDarkColor),
            ("taskTextOutsideColor", taskTextOutsideColor),
            ("taskTextClickableColor", taskTextClickableColor),
            ("vertLineColor", vertLineColor),
            ("gridColor", gridColor),
            ("todayLineColor", todayLineColor),
            ("textColor", textColor),
        ]
    }

    public static let dark = MermaidPalette(
        theme: "base",
        background: "#383E44",
        primaryColor: "#2F3135",
        primaryTextColor: "#E2E4E7",
        primaryBorderColor: "#727880",
        lineColor: "#D7DDE3",
        secondaryColor: "#383E44",
        secondaryTextColor: "#E2E4E7",
        tertiaryColor: "#212427",
        tertiaryTextColor: "#E2E4E7",
        mainBkg: "#252A2E",
        nodeBorder: "#838B94",
        nodeTextColor: "#F1F3F5",
        titleColor: "#F1F3F5",
        edgeLabelBackground: "#252A2E",
        erEdgeLabelBackground: "#252A2E",
        attributeBackgroundColorOdd: "#30363B",
        attributeBackgroundColorEven: "#252A2E",
        sectionBkgColor: "#252A2E",
        sectionBkgColor2: "#30363B",
        altSectionBkgColor: "#2A3035",
        taskBkgColor: "#4C5662",
        taskBorderColor: "#838B94",
        activeTaskBkgColor: "#596579",
        activeTaskBorderColor: "#A1A7AE",
        doneTaskBkgColor: "#3F474F",
        doneTaskBorderColor: "#727880",
        critBkgColor: "#6E4E54",
        critBorderColor: "#D48D8D",
        taskTextColor: "#F1F3F5",
        taskTextLightColor: "#F1F3F5",
        taskTextDarkColor: "#F1F3F5",
        taskTextOutsideColor: "#D7DDE3",
        taskTextClickableColor: "#F1F3F5",
        vertLineColor: "#D7DDE3",
        gridColor: "#727880",
        todayLineColor: "#D7DDE3",
        textColor: "#BCC3CA",
        fontFamily: "Helvetica Neue, Helvetica, Arial, sans-serif"
    )

    public static let light = MermaidPalette(
        theme: "base",
        background: "#FFFFFF",
        primaryColor: "#F6F8FA",
        primaryTextColor: "#24292F",
        primaryBorderColor: "#8C959F",
        lineColor: "#57606A",
        secondaryColor: "#FFFFFF",
        secondaryTextColor: "#24292F",
        tertiaryColor: "#F0F1F3",
        tertiaryTextColor: "#24292F",
        mainBkg: "#FFFFFF",
        nodeBorder: "#8C959F",
        nodeTextColor: "#24292F",
        titleColor: "#24292F",
        edgeLabelBackground: "#FFFFFF",
        erEdgeLabelBackground: "#FFFFFF",
        attributeBackgroundColorOdd: "#F6F8FA",
        attributeBackgroundColorEven: "#FFFFFF",
        sectionBkgColor: "#FFFFFF",
        sectionBkgColor2: "#F6F8FA",
        altSectionBkgColor: "#EFF3F6",
        taskBkgColor: "#DDEFFB",
        taskBorderColor: "#8C959F",
        activeTaskBkgColor: "#DDF4FF",
        activeTaskBorderColor: "#0969DA",
        doneTaskBkgColor: "#EAEFEE",
        doneTaskBorderColor: "#8C959F",
        critBkgColor: "#FFEBE9",
        critBorderColor: "#CF222E",
        taskTextColor: "#24292F",
        taskTextLightColor: "#24292F",
        taskTextDarkColor: "#24292F",
        taskTextOutsideColor: "#57606A",
        taskTextClickableColor: "#24292F",
        vertLineColor: "#57606A",
        gridColor: "#D0D7DE",
        todayLineColor: "#0969DA",
        textColor: "#24292F",
        fontFamily: "Helvetica Neue, Helvetica, Arial, sans-serif"
    )
}


/// Optional tab-strip token group (v1.2). Custom themes written before tabs
/// existed omit it entirely; `ReaderThemePalette.resolvedTab` derives a
/// coherent set from the sidebar/background tokens in that case. When the
/// group IS present, every field is required and validated like any other
/// theme color.
public struct TabPalette: Codable, Equatable, Sendable {
    public let barBackground: ReaderThemeColor
    public let barBorder: ReaderThemeColor
    public let restingFill: ReaderThemeColor
    public let hoverFill: ReaderThemeColor
    public let selectedFill: ReaderThemeColor
    public let selectedText: ReaderThemeColor
    public let unselectedText: ReaderThemeColor
    public let closeIcon: ReaderThemeColor
    public let closeHoverFill: ReaderThemeColor
    public let insertionIndicator: ReaderThemeColor

    public init(
        barBackground: ReaderThemeColor,
        barBorder: ReaderThemeColor,
        restingFill: ReaderThemeColor,
        hoverFill: ReaderThemeColor,
        selectedFill: ReaderThemeColor,
        selectedText: ReaderThemeColor,
        unselectedText: ReaderThemeColor,
        closeIcon: ReaderThemeColor,
        closeHoverFill: ReaderThemeColor,
        insertionIndicator: ReaderThemeColor
    ) {
        self.barBackground = barBackground
        self.barBorder = barBorder
        self.restingFill = restingFill
        self.hoverFill = hoverFill
        self.selectedFill = selectedFill
        self.selectedText = selectedText
        self.unselectedText = unselectedText
        self.closeIcon = closeIcon
        self.closeHoverFill = closeHoverFill
        self.insertionIndicator = insertionIndicator
    }

    public static let dark = TabPalette(
        barBackground: ReaderThemeColor(hex: "#212427"),
        barBorder: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.06),
        restingFill: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.02),
        hoverFill: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.06),
        selectedFill: ReaderThemeColor(hex: "#383E44"),
        selectedText: ReaderThemeColor(hex: "#E6E6E6", alpha: 0.96),
        unselectedText: ReaderThemeColor(hex: "#A8A8A8", alpha: 0.92),
        closeIcon: ReaderThemeColor(hex: "#A8A8A8", alpha: 0.92),
        closeHoverFill: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.1),
        insertionIndicator: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.9)
    )

    public static let light = TabPalette(
        barBackground: ReaderThemeColor(hex: "#F0F1F3"),
        barBorder: ReaderThemeColor(hex: "#000000", alpha: 0.08),
        restingFill: ReaderThemeColor(hex: "#000000", alpha: 0.02),
        hoverFill: ReaderThemeColor(hex: "#000000", alpha: 0.055),
        selectedFill: ReaderThemeColor(hex: "#FFFFFF"),
        selectedText: ReaderThemeColor(hex: "#24292F", alpha: 0.96),
        unselectedText: ReaderThemeColor(hex: "#59636E", alpha: 0.92),
        closeIcon: ReaderThemeColor(hex: "#59636E", alpha: 0.92),
        closeHoverFill: ReaderThemeColor(hex: "#000000", alpha: 0.08),
        insertionIndicator: ReaderThemeColor(hex: "#0969DA", alpha: 0.85)
    )
}

public struct ReaderThemePalette: Codable, Equatable, Sendable {
    public let name: String
    public let appearanceIsDark: Bool
    public let backgroundHex: String
    public let textHex: String
    public let headingHex: String
    public let minorHeadingHex: String
    public let secondaryTextHex: String
    public let linkHex: String
    public let linkHoverHex: String
    public let ruleHex: String
    public let codeBlockBackgroundHex: String
    public let inlineCodeBackgroundHex: String
    public let selectionHex: String
    public let selectionTextHex: String
    public let kbdTextHex: String
    public let kbdBorderHex: String
    public let kbdShadow: ReaderThemeColor
    public let calloutBackground: ReaderThemeColor
    public let calloutNoteBorder: ReaderThemeColor
    public let calloutNoteBackground: ReaderThemeColor
    public let calloutTipBorder: ReaderThemeColor
    public let calloutTipBackground: ReaderThemeColor
    public let calloutImportantBorder: ReaderThemeColor
    public let calloutImportantBackground: ReaderThemeColor
    public let calloutWarningBorder: ReaderThemeColor
    public let calloutWarningBackground: ReaderThemeColor
    public let calloutCautionBorder: ReaderThemeColor
    public let calloutCautionBackground: ReaderThemeColor
    public let symbolLinkTextHex: String
    public let symbolLinkBorder: ReaderThemeColor
    public let inlineChipBorder: ReaderThemeColor
    public let inlineChipBackground: ReaderThemeColor
    public let sidebarBackgroundHex: String
    public let sidebarSelectionHex: String
    public let sidebarHover: ReaderThemeColor
    public let sidebarChromeFill: ReaderThemeColor
    public let sidebarChromeBorder: ReaderThemeColor
    public let sidebarChromeSelectedFill: ReaderThemeColor
    public let sidebarChromeHoverFill: ReaderThemeColor
    public let sidebarPrimaryText: ReaderThemeColor
    public let sidebarSecondaryText: ReaderThemeColor
    public let titlebarPrimaryText: ReaderThemeColor
    public let findBarBackground: ReaderThemeColor
    public let findBarBorder: ReaderThemeColor
    public let statisticsLabel: ReaderThemeColor
    public let statisticsIcon: ReaderThemeColor
    public let statisticsIconButton: ReaderThemeColor
    public let statisticsPillRestingBackground: ReaderThemeColor
    public let statisticsPillHoverBackground: ReaderThemeColor
    public let statisticsPillHoverBorder: ReaderThemeColor
    public let statisticsIconButtonRestingBackground: ReaderThemeColor
    public let statisticsIconButtonHoverBackground: ReaderThemeColor
    public let statisticsIconButtonActiveBackground: ReaderThemeColor
    public let statisticsIconButtonHoverBorder: ReaderThemeColor
    public let mermaidContainerBackground: ReaderThemeColor
    public let mermaidContainerBorder: ReaderThemeColor
    public let mermaidGridStroke: ReaderThemeColor
    public let mermaidControlTextHex: String
    public let mermaidControlBackground: ReaderThemeColor
    public let mermaidControlBorder: ReaderThemeColor
    public let mermaidControlHoverBackgroundHex: String
    public let mermaidControlHoverBorder: ReaderThemeColor
    public let mermaidErrorTextHex: String
    public let mermaidSourceBackground: ReaderThemeColor
    public let diagramInspectorBackdrop: ReaderThemeColor
    public let diagramInspectorTextHex: String
    public let diagramInspectorToolbarBackground: ReaderThemeColor
    public let diagramInspectorToolbarBorder: ReaderThemeColor
    public let diagramInspectorButtonTextHex: String
    public let diagramInspectorButtonBackgroundHex: String
    public let diagramInspectorButtonBorder: ReaderThemeColor
    public let diagramInspectorButtonHoverBackgroundHex: String
    public let diagramInspectorButtonHoverBorder: ReaderThemeColor
    public let diagramInspectorViewportBackgroundHex: String
    public let diagramInspectorViewportBorder: ReaderThemeColor
    public let diagramInspectorViewportFocusOutline: ReaderThemeColor
    public let syntaxVariableHex: String
    public let syntaxKeywordHex: String
    public let syntaxStringHex: String
    public let syntaxCommentHex: String
    public let syntaxNumberHex: String
    public let syntaxAtomHex: String
    public let syntaxSecondaryVariableHex: String
    public let syntaxDefinitionHex: String
    public let syntaxPositiveHex: String
    public let syntaxNegativeHex: String
    public let mermaid: MermaidPalette
    public let tab: TabPalette?

    /// The tab tokens to render with: explicit when the theme defines them,
    /// otherwise derived from existing chrome tokens so pre-tab custom
    /// themes stay coherent without edits.
    public var resolvedTab: TabPalette {
        tab ?? TabPalette(
            barBackground: ReaderThemeColor(hex: sidebarBackgroundHex),
            barBorder: sidebarChromeBorder,
            restingFill: sidebarChromeFill,
            hoverFill: sidebarChromeHoverFill,
            selectedFill: ReaderThemeColor(hex: backgroundHex),
            selectedText: sidebarPrimaryText,
            unselectedText: sidebarSecondaryText,
            closeIcon: sidebarSecondaryText,
            closeHoverFill: sidebarChromeHoverFill,
            insertionIndicator: ReaderThemeColor(hex: linkHex, alpha: 0.9)
        )
    }

    public static let dark = ReaderThemePalette(
        name: "Dark",
        appearanceIsDark: true,
        backgroundHex: "#383E44",
        textHex: "#BCC3CA",
        headingHex: "#E2E4E7",
        minorHeadingHex: "#FFFFFF",
        secondaryTextHex: "#A1A7AE",
        linkHex: "#D7DDE3",
        linkHoverHex: "#FFFFFF",
        ruleHex: "#4C525A",
        codeBlockBackgroundHex: "#2F3135",
        inlineCodeBackgroundHex: "#30343A",
        selectionHex: "#4B84D1",
        selectionTextHex: "#FFFFFF",
        kbdTextHex: "#FFFFFF",
        kbdBorderHex: "#727880",
        kbdShadow: ReaderThemeColor(hex: "#000000", alpha: 0.22),
        calloutBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.04),
        calloutNoteBorder: ReaderThemeColor(hex: "#7DA1BC", alpha: 0.9),
        calloutNoteBackground: ReaderThemeColor(hex: "#7DA1BC", alpha: 0.11),
        calloutTipBorder: ReaderThemeColor(hex: "#7FB597", alpha: 0.9),
        calloutTipBackground: ReaderThemeColor(hex: "#7FB597", alpha: 0.11),
        calloutImportantBorder: ReaderThemeColor(hex: "#8F98D5", alpha: 0.92),
        calloutImportantBackground: ReaderThemeColor(hex: "#8F98D5", alpha: 0.11),
        calloutWarningBorder: ReaderThemeColor(hex: "#BF9866", alpha: 0.94),
        calloutWarningBackground: ReaderThemeColor(hex: "#BF9866", alpha: 0.12),
        calloutCautionBorder: ReaderThemeColor(hex: "#BE7D7D", alpha: 0.94),
        calloutCautionBackground: ReaderThemeColor(hex: "#BE7D7D", alpha: 0.12),
        symbolLinkTextHex: "#C8D6F0",
        symbolLinkBorder: ReaderThemeColor(hex: "#C8D6F0", alpha: 0.14),
        inlineChipBorder: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.08),
        inlineChipBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.055),
        sidebarBackgroundHex: "#212427",
        sidebarSelectionHex: "#1C2023",
        sidebarHover: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.028),
        sidebarChromeFill: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.024),
        sidebarChromeBorder: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.035),
        sidebarChromeSelectedFill: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.065),
        sidebarChromeHoverFill: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.04),
        sidebarPrimaryText: ReaderThemeColor(hex: "#E6E6E6", alpha: 0.96),
        sidebarSecondaryText: ReaderThemeColor(hex: "#A8A8A8", alpha: 0.92),
        titlebarPrimaryText: ReaderThemeColor(hex: "#E6E6E6", alpha: 0.72),
        findBarBackground: ReaderThemeColor(hex: "#484848", alpha: 0.94),
        findBarBorder: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.08),
        statisticsLabel: ReaderThemeColor(hex: "#DBDBDB", alpha: 0.98),
        statisticsIcon: ReaderThemeColor(hex: "#D1D1D1", alpha: 0.9),
        statisticsIconButton: ReaderThemeColor(hex: "#D1D1D1", alpha: 0.92),
        statisticsPillRestingBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.045),
        statisticsPillHoverBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.08),
        statisticsPillHoverBorder: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.14),
        statisticsIconButtonRestingBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.03),
        statisticsIconButtonHoverBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.07),
        statisticsIconButtonActiveBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.12),
        statisticsIconButtonHoverBorder: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.12),
        mermaidContainerBackground: ReaderThemeColor(hex: "#2F3135", alpha: 0.78),
        mermaidContainerBorder: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.12),
        mermaidGridStroke: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.34),
        mermaidControlTextHex: "#F1F3F5",
        mermaidControlBackground: ReaderThemeColor(hex: "#1C2023", alpha: 0.92),
        mermaidControlBorder: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.26),
        mermaidControlHoverBackgroundHex: "#1C2023",
        mermaidControlHoverBorder: ReaderThemeColor(hex: "#F1F3F5", alpha: 0.58),
        mermaidErrorTextHex: "#E7B0B0",
        mermaidSourceBackground: ReaderThemeColor(hex: "#000000", alpha: 0.14),
        diagramInspectorBackdrop: ReaderThemeColor(hex: "#121416", alpha: 0.86),
        diagramInspectorTextHex: "#F1F3F5",
        diagramInspectorToolbarBackground: ReaderThemeColor(hex: "#212427", alpha: 0.94),
        diagramInspectorToolbarBorder: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.14),
        diagramInspectorButtonTextHex: "#F1F3F5",
        diagramInspectorButtonBackgroundHex: "#2F3135",
        diagramInspectorButtonBorder: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.18),
        diagramInspectorButtonHoverBackgroundHex: "#383E44",
        diagramInspectorButtonHoverBorder: ReaderThemeColor(hex: "#F1F3F5", alpha: 0.52),
        diagramInspectorViewportBackgroundHex: "#2F3135",
        diagramInspectorViewportBorder: ReaderThemeColor(hex: "#D7DDE3", alpha: 0.14),
        diagramInspectorViewportFocusOutline: ReaderThemeColor(hex: "#F1F3F5", alpha: 0.54),
        syntaxVariableHex: "#D2D8EA",
        syntaxKeywordHex: "#CB94D4",
        syntaxStringHex: "#D87272",
        syntaxCommentHex: "#D59452",
        syntaxNumberHex: "#68AE95",
        syntaxAtomHex: "#87B8CC",
        syntaxSecondaryVariableHex: "#A2BCD7",
        syntaxDefinitionHex: "#9496EF",
        syntaxPositiveHex: "#88C09D",
        syntaxNegativeHex: "#D48D8D",
        mermaid: .dark,
        tab: .dark
    )

    public static let light = ReaderThemePalette(
        name: "Light",
        appearanceIsDark: false,
        backgroundHex: "#FFFFFF",
        textHex: "#1F2328",
        headingHex: "#0B0F14",
        minorHeadingHex: "#0B0F14",
        secondaryTextHex: "#59636E",
        linkHex: "#0969DA",
        linkHoverHex: "#054DA7",
        ruleHex: "#D0D7DE",
        codeBlockBackgroundHex: "#F3F4F6",
        inlineCodeBackgroundHex: "#F6F8FA",
        selectionHex: "#B3D4FC",
        selectionTextHex: "#0B0F14",
        kbdTextHex: "#24292F",
        kbdBorderHex: "#B6BEC8",
        kbdShadow: ReaderThemeColor(hex: "#000000", alpha: 0.12),
        calloutBackground: ReaderThemeColor(hex: "#F6F8FA", alpha: 0.75),
        calloutNoteBorder: ReaderThemeColor(hex: "#0969DA", alpha: 0.72),
        calloutNoteBackground: ReaderThemeColor(hex: "#DDF4FF", alpha: 0.65),
        calloutTipBorder: ReaderThemeColor(hex: "#1A7F37", alpha: 0.72),
        calloutTipBackground: ReaderThemeColor(hex: "#DAFBE1", alpha: 0.65),
        calloutImportantBorder: ReaderThemeColor(hex: "#8250DF", alpha: 0.72),
        calloutImportantBackground: ReaderThemeColor(hex: "#F0E7FF", alpha: 0.68),
        calloutWarningBorder: ReaderThemeColor(hex: "#9A6700", alpha: 0.74),
        calloutWarningBackground: ReaderThemeColor(hex: "#FFF8C5", alpha: 0.7),
        calloutCautionBorder: ReaderThemeColor(hex: "#CF222E", alpha: 0.74),
        calloutCautionBackground: ReaderThemeColor(hex: "#FFEBE9", alpha: 0.72),
        symbolLinkTextHex: "#0969DA",
        symbolLinkBorder: ReaderThemeColor(hex: "#0969DA", alpha: 0.18),
        inlineChipBorder: ReaderThemeColor(hex: "#57606A", alpha: 0.14),
        inlineChipBackground: ReaderThemeColor(hex: "#F6F8FA", alpha: 0.96),
        sidebarBackgroundHex: "#F0F1F3",
        sidebarSelectionHex: "#E1E4E8",
        sidebarHover: ReaderThemeColor(hex: "#000000", alpha: 0.04),
        sidebarChromeFill: ReaderThemeColor(hex: "#000000", alpha: 0.035),
        sidebarChromeBorder: ReaderThemeColor(hex: "#000000", alpha: 0.08),
        sidebarChromeSelectedFill: ReaderThemeColor(hex: "#000000", alpha: 0.09),
        sidebarChromeHoverFill: ReaderThemeColor(hex: "#000000", alpha: 0.055),
        sidebarPrimaryText: ReaderThemeColor(hex: "#24292F", alpha: 0.96),
        sidebarSecondaryText: ReaderThemeColor(hex: "#59636E", alpha: 0.92),
        titlebarPrimaryText: ReaderThemeColor(hex: "#24292F", alpha: 0.72),
        findBarBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.96),
        findBarBorder: ReaderThemeColor(hex: "#1F2328", alpha: 0.12),
        statisticsLabel: ReaderThemeColor(hex: "#24292F", alpha: 0.98),
        statisticsIcon: ReaderThemeColor(hex: "#59636E", alpha: 0.9),
        statisticsIconButton: ReaderThemeColor(hex: "#59636E", alpha: 0.92),
        statisticsPillRestingBackground: ReaderThemeColor(hex: "#000000", alpha: 0.035),
        statisticsPillHoverBackground: ReaderThemeColor(hex: "#000000", alpha: 0.07),
        statisticsPillHoverBorder: ReaderThemeColor(hex: "#000000", alpha: 0.13),
        statisticsIconButtonRestingBackground: ReaderThemeColor(hex: "#000000", alpha: 0.035),
        statisticsIconButtonHoverBackground: ReaderThemeColor(hex: "#000000", alpha: 0.07),
        statisticsIconButtonActiveBackground: ReaderThemeColor(hex: "#000000", alpha: 0.12),
        statisticsIconButtonHoverBorder: ReaderThemeColor(hex: "#000000", alpha: 0.13),
        mermaidContainerBackground: ReaderThemeColor(hex: "#F6F8FA", alpha: 0.86),
        mermaidContainerBorder: ReaderThemeColor(hex: "#D0D7DE", alpha: 0.95),
        mermaidGridStroke: ReaderThemeColor(hex: "#D0D7DE", alpha: 0.95),
        mermaidControlTextHex: "#24292F",
        mermaidControlBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.94),
        mermaidControlBorder: ReaderThemeColor(hex: "#8C959F", alpha: 0.35),
        mermaidControlHoverBackgroundHex: "#F6F8FA",
        mermaidControlHoverBorder: ReaderThemeColor(hex: "#57606A", alpha: 0.48),
        mermaidErrorTextHex: "#A40E26",
        mermaidSourceBackground: ReaderThemeColor(hex: "#F6F8FA", alpha: 1),
        diagramInspectorBackdrop: ReaderThemeColor(hex: "#F6F8FA", alpha: 0.92),
        diagramInspectorTextHex: "#24292F",
        diagramInspectorToolbarBackground: ReaderThemeColor(hex: "#FFFFFF", alpha: 0.96),
        diagramInspectorToolbarBorder: ReaderThemeColor(hex: "#D0D7DE", alpha: 1),
        diagramInspectorButtonTextHex: "#24292F",
        diagramInspectorButtonBackgroundHex: "#F6F8FA",
        diagramInspectorButtonBorder: ReaderThemeColor(hex: "#D0D7DE", alpha: 1),
        diagramInspectorButtonHoverBackgroundHex: "#EAEEF2",
        diagramInspectorButtonHoverBorder: ReaderThemeColor(hex: "#8C959F", alpha: 0.75),
        diagramInspectorViewportBackgroundHex: "#FFFFFF",
        diagramInspectorViewportBorder: ReaderThemeColor(hex: "#D0D7DE", alpha: 1),
        diagramInspectorViewportFocusOutline: ReaderThemeColor(hex: "#0969DA", alpha: 0.5),
        syntaxVariableHex: "#0B5CAD",
        syntaxKeywordHex: "#8250DF",
        syntaxStringHex: "#A40E26",
        syntaxCommentHex: "#6E7781",
        syntaxNumberHex: "#116329",
        syntaxAtomHex: "#0550AE",
        syntaxSecondaryVariableHex: "#57606A",
        syntaxDefinitionHex: "#6639BA",
        syntaxPositiveHex: "#1A7F37",
        syntaxNegativeHex: "#CF222E",
        mermaid: .light,
        tab: .light
    )
}
