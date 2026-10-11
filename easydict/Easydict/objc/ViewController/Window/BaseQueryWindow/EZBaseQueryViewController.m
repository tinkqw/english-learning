//
//  MainTabViewController.m
//  Easydict
//
//  Created by tisfeng on 2022/11/3.
//  Copyright © 2022 izual. All rights reserved.
//

#import "EZBaseQueryViewController.h"
#import <Easydict-Swift.h>
#import "EZQueryView.h"
#import "EZResultView.h"
#import "EZSelectLanguageCell.h"
#import "EZCoordinateUtils.h"
#import "EZEnumTypes.h"
#import "EZAudioPlayer.h"
#import "EZTableRowView.h"
#import "EZSchemeParser.h"
#import "EZToast.h"
#import "DictionaryKit.h"
#import "EZWebViewManager.h"


static NSString *const EZQueryViewId = @"EZQueryViewId";
static NSString *const EZSelectLanguageCellId = @"EZSelectLanguageCellId";
static NSString *const EZTableTipsCellId = @"EZTableTipsCellId";
static NSString *const EZResultViewId = @"EZResultViewId";

static NSString *const EZColumnId = @"EZColumnId";

static NSString *const kDCSActiveDictionariesChangedDistributedNotification = @"kDCSActiveDictionariesChangedDistributedNotification";

/// Execute block on main thread safely.
static void dispatch_block_on_main_safely(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

/// Compare frames with a tolerance to avoid tiny floating-point oscillations.
static BOOL ez_frame_equal_with_tolerance(CGRect lhs, CGRect rhs, CGFloat tolerance) {
    return ABS(CGRectGetMinX(lhs) - CGRectGetMinX(rhs)) <= tolerance &&
        ABS(CGRectGetMinY(lhs) - CGRectGetMinY(rhs)) <= tolerance &&
        ABS(CGRectGetWidth(lhs) - CGRectGetWidth(rhs)) <= tolerance &&
        ABS(CGRectGetHeight(lhs) - CGRectGetHeight(rhs)) <= tolerance;
}

@interface EZBaseQueryViewController () <NSTableViewDelegate, NSTableViewDataSource, WKNavigationDelegate>

@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) EZMainQuerySurface *mainSurface;
@property (nonatomic, assign) BOOL mainSideBySide;
@property (nonatomic, strong) NSMutableSet<NSString *> *incompleteWindowSnapshots;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTableColumn *column;

@property (nonatomic, strong) EZQueryView *queryView;
@property (nonatomic, strong) EZSelectLanguageCell *selectLanguageCell;
@property (nonatomic, strong) EZTableTipsCell *tipsCell;

// queryText is self.queryModel.queryText;
@property (nonatomic, copy, readonly) NSString *queryText;
@property (nonatomic, strong) NSArray<NSString *> *serviceTypeIds;
@property (nonatomic, strong) NSArray<EZQueryService *> *services;
@property (nonatomic, strong, readwrite) EZQueryModel *queryModel;

@property (nonatomic, strong) EZQueryService *firstService;

@property (nonatomic, strong) EZQueryService *defaultTTSService;
@property (nonatomic, strong) EZQueryService *youdaoService;

/// Transient word lookup has an independent model and presentation.
@property (nonatomic, strong, nullable) EZQueryService *inlineLookupService;
@property (nonatomic, copy, nullable) NSString *inlineLookupWord;
@property (nonatomic, strong, nullable) EZInlineLookupPopover *inlineLookupPopover;
@property (nonatomic, strong, nullable) EZWordResultView *inlineLookupContent;

@property (nonatomic, strong) EZDetectManager *detectManager;
@property (nonatomic, strong) EZAudioPlayer *audioPlayer;
@property (nonatomic, strong) EZSchemeParser *schemeParser;

@property (nonatomic, assign) BOOL lockResizeWindow;
@property (nonatomic, assign) BOOL isUpdatingWindowFrameInternally;

@property (nonatomic, assign) EZTipsCellType tipsCellType;

@property (nonatomic, copy) NSString *tipsCellContent;

@property (nonatomic, assign) BOOL isInputFieldCellVisible;
@property (nonatomic, assign) BOOL isSelectLanguageCellVisible;
@property (nonatomic, assign) BOOL isTipsViewVisible;

@property (nonatomic, assign) NSInteger inputFieldCellIndex;     // always 0
@property (nonatomic, assign) NSInteger selectLanguageCellIndex; // 0 or 1
@property (nonatomic, assign) NSInteger tipsCellIndex;           // 0 or 1 or 2

@property (nonatomic, strong) MyConfiguration *config;
@property (nonatomic, strong) id fontSizeObserver;

/// Presentation state does not change service scheduling or firstService.
@property (nonatomic, strong) EZPopupServiceBar *popupServiceBar;
@property (nonatomic, copy) NSString *selectedPopupServiceID;
@property (nonatomic, strong) NSMutableSet<NSString *> *stoppedPopupServices;
@property (nonatomic, strong) NSMutableSet<NSString *> *runningPopupServices;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *popupScrollPositions;

@end

@implementation EZBaseQueryViewController

/// !!!: Must init with a type, update NSNotification need window type.
- (instancetype)init {
    return [self initWithWindowType:EZWindowTypeFixed];
}

- (instancetype)initWithWindowType:(EZWindowType)type {
    MMLogInfo(@"init EZBaseQueryViewController with type: %@", @(type));
    if (self = [super init]) {
        self.windowType = type;
        [self setupUI];
        [self setupData];
        [self updateWindowHeight];
    }
    return self;
}

/// 用代码创建 NSViewController 貌似不会自动创建 view，需要手动初始化
- (void)loadView {
    CGRect frame = [[EZLayoutManager shared] windowFrameWithType:self.windowType];
    self.view = [[NSView alloc] initWithFrame:frame];
    self.view.wantsLayer = YES;
    self.view.layer.cornerRadius = [self usesTabbedDesign] ? 22 : EZCornerRadius_8;
    self.view.layer.masksToBounds = YES;
    if ([self usesTabbedDesign]) {
        NSVisualEffectView *material = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        material.material = NSVisualEffectMaterialPopover;
        material.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        material.state = NSVisualEffectStateActive;
        material.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:material];
        NSView *shellTint = [[NSView alloc] initWithFrame:self.view.bounds];
        shellTint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [shellTint executeLight:^(NSView *view) {
            [EZPopupAppearance applyShellToView:view];
        } dark:^(NSView *view) {
            [EZPopupAppearance applyShellToView:view];
        }];
        [self.view addSubview:shellTint];
    }
    BOOL popupDesign = [self usesTabbedDesign];
    [self.view executeLight:^(NSView *_Nonnull x) {
        if (popupDesign) { [EZPopupAppearance applyShellToView:x]; }
        else { x.layer.backgroundColor = [NSColor ez_mainViewBgLightColor].CGColor; }
    } dark:^(NSView *_Nonnull x) {
        if (popupDesign) { [EZPopupAppearance applyShellToView:x]; }
        else { x.layer.backgroundColor = [NSColor ez_mainViewBgDarkColor].CGColor; }
    }];
}


- (void)viewDidLoad {
    [super viewDidLoad];
}

- (void)viewWillAppear {
    [super viewWillAppear];

    [EZAnalyticsService logWindowAppear:self.windowType];
    if (self.windowType == EZWindowTypeMain) {
        [self updateWindowHeight];
    }
}


- (void)setupData {
    self.queryModel = [[EZQueryModel alloc] init];
    self.config = MyConfiguration.shared;

    self.detectManager = [EZDetectManager managerWithModel:self.queryModel];

    [self setupServices:[self latestServices]];
    [self resetQueryAndResults];

    [self updateWindowConfiguration:nil];
}

- (void)setupUI {
    [self tableView];

    mm_weakify(self);
    [self setResizeWindowBlock:^{
        mm_strongify(self);

        // Avoid recycling call, resize window --> update window height --> resize window
        if (self.lockResizeWindow || self.isUpdatingWindowFrameInternally) {
            //            MMLogInfo(@"lockResizeWindow");
            return;
        }
        
        MMLogInfo(@"resize window, update window height");

        [self dismissInlineLookup];
        [self setNeedUpdateIframeHeightForAllResults];

        [self reloadTableViewDataWithoutWindowHeightUpdate:^{
            // Update query view height manually, and update cell height.
            CGFloat queryViewHeight = [self.queryView heightOfQueryView];
            if (queryViewHeight) {
                self.queryModel.queryViewHeight = queryViewHeight;

                if (self.isInputFieldCellVisible && self.windowType != EZWindowTypeMain) {
                    NSIndexSet *firstIndexSet = [NSIndexSet indexSetWithIndex:0];
                    [self.tableView noteHeightOfRowsWithIndexesChanged:firstIndexSet];
                }
            }

            [self updateWindowHeight];
        }];
    }];


    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];

    [defaultCenter addObserver:self
                      selector:@selector(handleServiceUpdate:)
                          name:NSNotification.serviceHasUpdated
                        object:nil];

    [defaultCenter addObserver:self
                      selector:@selector(boundsDidChangeNotification:)
                          name:NSViewBoundsDidChangeNotification
                        object:[self.scrollView contentView]];

    // ???: FIX [dcs_error] kDCSActiveDictionariesChangedDistributedNotification catched, but it seems does not work.
    [defaultCenter addObserver:self
                      selector:@selector(activeDictionariesChanged:)
                          name:kDCSActiveDictionariesChangedDistributedNotification
                        object:nil];

    self.fontSizeObserver = [defaultCenter addObserverForName:NSNotification.didChangeFontSize
                               object:nil
                                queue:NSOperationQueue.mainQueue
                           usingBlock:^(NSNotification *_Nonnull notification) {
                               mm_strongify(self);
                               [self dismissInlineLookup];
                               [self reloadTableViewData:^{
                                   [self updateTableViewHeight];
                                   if ([self usesTabbedDesign]) {
                                       [self updateWindowHeight];
                                   }
                               }];
                           }];

    [defaultCenter addObserver:self
                      selector:@selector(modifyAppLanguage:)
                          name:NSNotification.languagePreferenceChanged
                        object:nil];

    [defaultCenter addObserver:self
                      selector:@selector(updateWindowConfiguration:)
                          name:NSNotification.didChangeWindowConfiguration
                        object:nil];

    // Observe for max window height settings changes
    [defaultCenter addObserver:self
                      selector:@selector(updateWindowHeight)
                          name:NSNotification.maxWindowHeightSettingsChanged
                        object:nil];
}

- (void)updateWindowConfiguration:(NSNotification *)notification {
    UpdateNotificationInfo *info = notification.object;
    if (info && info.windowType != self.windowType) {
        return;
    }

    self.queryModel.queryViewHeight = [self miniQueryViewHeight];

    self.isInputFieldCellVisible = [self.config showInputTextFieldWithKey:WindowConfigurationKeyInputFieldCellVisible
                                                               windowType:self.windowType];
    self.isSelectLanguageCellVisible = [self.config showInputTextFieldWithKey:WindowConfigurationKeySelectLanguageCellVisible
                                                                   windowType:self.windowType];

    self.inputFieldCellIndex = 0;

    if (self.isInputFieldCellVisible && self.windowType != EZWindowTypeMain) {
        if (self.isSelectLanguageCellVisible && ![self embedsPopupLanguageHeader]) {
            self.selectLanguageCellIndex = 1;
            self.tipsCellIndex = 2;
        } else {
            self.tipsCellIndex = 1;
        }
    } else {
        if (self.isSelectLanguageCellVisible && ![self embedsPopupLanguageHeader]) {
            self.selectLanguageCellIndex = 0;
            self.tipsCellIndex = 1;
        } else {
            self.tipsCellIndex = 0;
        }
    }

    if (self.windowType == EZWindowTypeMain) {
        [self updateMainSourceView];
    }
    [self reloadTableViewData:nil];
}

- (void)modifyAppLanguage:(NSNotification *)notification {
    [self updatePopupServiceBar];
    [self.tableView reloadData];
}

- (void)setupServices:(NSArray *)allServices {
    NSMutableArray *serviceTypeIds = [NSMutableArray array];
    NSMutableArray *services = [NSMutableArray array];

    self.youdaoService = nil;
    _defaultTTSService = nil;
    EZServiceType defaultTTSServiceType = self.config.defaultTTSServiceType;

    for (EZQueryService *service in allServices) {
        if (service.enabled) {
            [self resetService:service];

            [services addObject:service];
            [serviceTypeIds addObject:service.serviceTypeWithUniqueIdentifier];
        }

        EZServiceType serviceType = service.serviceType;
        if ([serviceType isEqualToString:EZServiceTypeYoudao]) {
            self.youdaoService = service;
        }

        if ([serviceType isEqualToString:defaultTTSServiceType]) {
            _defaultTTSService = service;
        }
    }
    self.services = services;
    self.serviceTypeIds = serviceTypeIds;
    if (!self.selectedPopupServiceID || ![serviceTypeIds containsObject:self.selectedPopupServiceID]) {
        self.selectedPopupServiceID = services.count ? [services.firstObject serviceTypeWithUniqueIdentifier] : nil;
    }
    self.stoppedPopupServices = [NSMutableSet set];
    self.runningPopupServices = [NSMutableSet set];
    self.popupScrollPositions = [NSMutableDictionary dictionary];
    self.incompleteWindowSnapshots = [NSMutableSet set];

    self.audioPlayer = [[EZAudioPlayer alloc] init];
    if (!self.youdaoService) {
        self.youdaoService = [EZLocalStorage.shared service:EZServiceTypeYoudao windowType:self.windowType];
    }
}

- (void)dealloc {
    MMLogInfo(@"dealloc: %@", self);

    [_inlineLookupPopover dismiss];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_fontSizeObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_fontSizeObserver];
    }
}

#pragma mark - NSNotificationCenter

- (void)activeDictionariesChanged:(NSNotification *)notification {
    MMLogInfo(@"Active dictionaries changed: %@", notification);
}

- (void)handleServiceUpdate:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    EZWindowType windowType = [userInfo[UserInfoKey.windowType] integerValue];
    NSString *serviceType = userInfo[UserInfoKey.serviceType];
    BOOL autoQuery = [userInfo[UserInfoKey.autoQuery] boolValue];

    MMLogInfo(@"handle service update notification: %@, userInfo: %@", serviceType, userInfo);

    if ([serviceType length] != 0) {
        [self updateService:serviceType autoQuery:autoQuery];
        return;
    }

    if (!userInfo || windowType == self.windowType || windowType == EZWindowTypeNone) {
        [self resetAllCellWithServices:[self latestServices] completion:^{
            if (autoQuery) {
                [self queryCurrentModel];
            }
        }];
    }
}

- (void)boundsDidChangeNotification:(NSNotification *)notification {
    // TODO: need to optimize. Manually update the cell height, because the reused cell will not self-adjust the height.
    //    [self updateAllResultCellHeightIfNeed];
    [self updateTableViewHeight];
    [self.inlineLookupPopover reposition];
}

#pragma mark - Getter && Setter

- (NSScrollView *)scrollView {
    if (!_scrollView) {
        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:self.view.bounds];
        NSView *container = self.view;
        if (self.windowType == EZWindowTypeMain) {
            self.mainSurface = [[EZMainQuerySurface alloc] initWithFrame:NSInsetRect(self.view.bounds, 10, 10)];
            [self.view addSubview:self.mainSurface];
            [self.mainSurface mas_makeConstraints:^(MASConstraintMaker *make) {
                make.edges.equalTo(self.view).inset(10);
            }];
            [self.mainSurface layoutSubtreeIfNeeded];
            container = self.mainSurface.resultContainer;
        }
        [container addSubview:scrollView];
        _scrollView = scrollView;

        scrollView.drawsBackground = ![self usesTabbedDesign];
        scrollView.wantsLayer = YES;
        scrollView.layer.cornerRadius = EZCornerRadius_8;
        BOOL popupDesign = [self usesTabbedDesign];
        [scrollView executeLight:^(NSScrollView *scrollView) {
            scrollView.backgroundColor = popupDesign ? NSColor.clearColor : [NSColor ez_mainViewBgLightColor];
        } dark:^(NSScrollView *scrollView) {
            scrollView.backgroundColor = popupDesign ? NSColor.clearColor : [NSColor ez_mainViewBgDarkColor];
        }];

        [scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.equalTo(container);
            if (self.windowType != EZWindowTypeMain) {
                CGSize miniWindowSize = [EZLayoutManager.shared minimumWindowSize:self.windowType];
                make.width.mas_greaterThanOrEqualTo(miniWindowSize.width);
                make.height.mas_greaterThanOrEqualTo(miniWindowSize.height);
            }
        }];

        scrollView.hasVerticalScroller = YES;
        scrollView.verticalScroller.controlSize = NSControlSizeSmall;
        [scrollView setAutomaticallyAdjustsContentInsets:NO];

        CGFloat bottomInset = EZHorizontalCellSpacing_10 - EZVerticalCellSpacing_7 / 2;
        scrollView.contentInsets = NSEdgeInsetsMake(0, 0, bottomInset, 0);
    }
    return _scrollView;
}

- (NSTableView *)tableView {
    if (!_tableView) {
        NSTableView *tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
        _tableView = tableView;
        tableView.wantsLayer = YES;
        tableView.layer.drawsAsynchronously = YES;

        BOOL popupDesign = [self usesTabbedDesign];
        [tableView executeLight:^(NSTableView *tableView) {
            tableView.backgroundColor = popupDesign ? NSColor.clearColor : [NSColor ez_mainViewBgLightColor];
        } dark:^(NSTableView *tableView) {
            tableView.backgroundColor = popupDesign ? NSColor.clearColor : [NSColor ez_mainViewBgDarkColor];
        }];

        tableView.style = NSTableViewStylePlain;

        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:EZColumnId];
        self.column = column;
        column.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
        [tableView addTableColumn:column];

        tableView.delegate = self;
        tableView.dataSource = self;
        // Don't let clicks on the table body steal first responder from the input
        // text view, which interrupts typing. Cell subviews (the input field and
        // selectable result text) keep their own first-responder behavior.
        tableView.refusesFirstResponder = YES;
        tableView.rowHeight = 40;
        [tableView setAutoresizesSubviews:YES];
        [tableView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];

        tableView.headerView = nil;
        tableView.intercellSpacing = CGSizeMake(2 * EZHorizontalCellSpacing_10, EZVerticalCellSpacing_7);
        tableView.gridColor = NSColor.clearColor;
        self.scrollView.documentView = tableView;
        [tableView sizeLastColumnToFit]; // must put in the end
    }
    return _tableView;
}

- (EZSchemeParser *)schemeParser {
    if (!_schemeParser) {
        _schemeParser = [[EZSchemeParser alloc] init];
    }
    return _schemeParser;
}

- (EZAudioPlayer *)audioPlayer {
    if (!_audioPlayer) {
        _audioPlayer = [[EZAudioPlayer alloc] init];
    }
    return _audioPlayer;
}

- (void)setInputText:(NSString *)inputText {
    // !!!: Rewrite property copy setter. Avoid text being affected.
    _inputText = [inputText copy];

    self.queryModel.inputText = _inputText;


    [self updateQueryViewModelAndDetectedLanguage:self.queryModel];
}

- (NSString *)queryText {
    NSString *queryText = self.queryModel.queryText;
    return queryText;
}

- (EZQueryService *)defaultTTSService {
    EZServiceType defaultTTSServiceType = self.config.defaultTTSServiceType;
    if (![_defaultTTSService.serviceType isEqualToString:defaultTTSServiceType]) {
        _defaultTTSService = [QueryServiceFactory.shared serviceWithTypeId:defaultTTSServiceType];
    }
    return _defaultTTSService;
}

#pragma mark - Public Methods

/// Recreate the query model and rebind dependent managers for background OCR.
- (void)resetQueryModelForBackgroundOCR {
    EZQueryModel *model = [[EZQueryModel alloc] init];
    model.userSourceLanguage = MyConfiguration.shared.fromLanguage;
    model.userTargetLanguage = MyConfiguration.shared.toLanguage;

    self.queryModel = model;
    self.detectManager = [EZDetectManager managerWithModel:model];

    for (EZQueryService *service in self.services) {
        service.queryModel = model;
    }

    if (self.queryView) {
        self.queryView.queryModel = model;
    }

    if (self.selectLanguageCell) {
        self.selectLanguageCell.queryModel = model;
    }
}

/// Before starting query text, close all result view.
- (void)startQueryText:(NSString *)text {
    [self startQueryText:text actionType:self.queryModel.actionType];
}

- (void)startQueryText:(NSString *)text actionType:(EZActionType)actionType {
    MMLogInfo(@"query actionType: %@", actionType);

    if ([text  ns_trim].length == 0) {
        MMLogWarn(@"query text is empty");
        return;
    }

    self.inputText = text;
    self.queryModel.actionType = actionType;
    self.queryView.isTypingChinese = NO;

    if ([self handleEasydictScheme:text]) {
        return;
    }

    // Before starting new query, we should stop the previous query.
    [self.queryModel stopAllService];

    // Close all resultView before querying new text.
    [self closeAllResultView:^{
        self.inputText = text;
        [self queryCurrentModel];
    }];
}

/// Handle Easydict scheme.
- (BOOL)handleEasydictScheme:(NSString *)text {
    BOOL isEasydictScheme = [self.schemeParser isEasydictScheme:text];
    if (!isEasydictScheme) {
        return NO;
    }

    [self.schemeParser openURLScheme:text completion:^(BOOL isSuccess, NSString *_Nullable returnValue, NSString *_Nullable actionKey) {
        NSString *message = isSuccess ? @"Success" : @"Failed";
        if (returnValue.length > 0) {
            message = returnValue;
        }

        [EZToast showToast:message];

        if (!isSuccess) {
            return;
        }

        [self clearInput];

        // If write, need to update.
        if (actionKey && [self.schemeParser isWriteActionKey:actionKey]) {
            // Besides current window, other pages need to be notified, such as the settings service page.
            [NSNotificationCenter.defaultCenter postServiceUpdateNotification];
        }
    }];

    return YES;
}

- (void)startOCRImage:(NSImage *)image
           actionType:(EZActionType)actionType
            autoQuery:(BOOL)autoQuery {
    MMLogInfo(@"start OCR Image: %@, actionType: %@", @(image.size), actionType);
    MMLogInfo(@"ocr language: %@", self.queryModel.queryFromLanguage);

    self.queryModel.actionType = actionType;
    self.queryModel.ocrImage = image;

    self.queryView.isTypingChinese = NO;
    [self.queryView startLoadingAnimation:YES];

    // Hide previous tips view first.
    [self showTipsView:NO completion:nil];

    mm_weakify(self);
    [self.detectManager ocrAndDetectTextWithCompletion:^(EZQueryModel *_Nonnull queryModel, NSError *_Nullable error) {
        mm_strongify(self);
        if (self.queryModel != queryModel) { return; }
        // !!!: inputText should be used here, not queryText, queryText may be modified, such as easydict://query?text=xxx
        NSString *inputText = queryModel.inputText;
        MMLogInfo(@"ocr result: %@", inputText);

        NSDictionary *dict = @{
            @"detectedLanguage" : queryModel.detectedLanguage,
            @"actionType" : actionType,
        };
        [EZAnalyticsService logEventWithName:@"ocr" parameters:dict];


        if (actionType == EZActionTypeScreenshotOCR) {
            [inputText copyToPasteboard];

            dispatch_block_on_main_safely(^{
                [EZToast showSuccessToast];
            });

            return;
        }


        if (actionType != EZActionTypeScreenshotOCR) {
            [self.queryView startLoadingAnimation:NO];

            self.inputText = inputText;

            // Show detected language, even auto
            self.queryModel.showAutoLanguage = YES;

            [self updateQueryTextAndParagraphStyle:inputText actionType:actionType];

            if (error) {
                NSString *errorMsg = [error localizedDescription];
                [self showTipsView:YES content:errorMsg type:EZTipsCellTypeErrorTips];
                return;
            }

            if (self.config.autoCopyOCRText) {
                [inputText copyToPasteboard];
            }

            [self.queryView highlightAllLinks];

            if ([self.inputText ns_isURL]) {
                // Append a whitespace to beautify the link.
                self.inputText = [self.inputText stringByAppendingString:@" "];

                return;
            }

            if (autoQuery) {
                [self startQueryText];
            }
        }
    }];
}

- (void)retryQueryWithLanguage:(EZLanguage)language {
    MMLogInfo(@"Retry query with language: %@", language);

    [self.audioPlayer stop];

    // Reset query view height if we are retrying OCR query
    if (self.queryModel.ocrImage) {
        self.inputText = @"";
    }

    // If has designated language, we don't need to detect language again.
    if (language == EZLanguageAuto) {
        self.queryModel.detectedLanguage = EZLanguageAuto;
        self.queryModel.needDetectLanguage = YES;
    } else {
        self.queryModel.detectedLanguage = language;
        self.queryModel.needDetectLanguage = NO;
    }

    [self closeAllResultView:^{
        [self startQueryWithType:self.queryModel.actionType];
    }];
}

- (void)focusInputTextView {
    // Fix ⚠️: ERROR: Setting <EZTextView: 0x13d82c5d0> as the first responder for window <EZFixedQueryWindow: 0x11c607800>, but it is in a different window ((null))! This would eventually crash when the view is freed. The first responder will be set to nil.
    if (self.queryView.window == self.baseQueryWindow) {
        // Delay to make textView the first responder.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.baseQueryWindow makeFirstResponder:self.queryView.textView];
            if (self.config.selectQueryTextWhenWindowActivate) {
                self.queryView.textView.selectedRange = NSMakeRange(0, self.inputText.length);
            }
        });
    }
}

- (void)cancelAutoQuery {
    [self.queryView cancelAutoQuery];
}

- (void)dismissInlineLookup {
    [self removeInlineLookupServiceReloadData:YES];
}

- (BOOL)dismissInlineLookupIfVisible {
    if (!self.inlineLookupService) { return NO; }
    [self dismissInlineLookup];
    return YES;
}

- (void)clearInput {
    // Clear query text, detect language and clear button right now;
    self.inputText = @"";
    self.queryModel.ocrImage = nil;
    [self.queryView setAlertTextHidden:YES];

    [self.audioPlayer stop];
}

- (void)clearAll {
    [self clearInput];

    [self updateQueryCellWithCompletionHandler:^{
        // !!!: To show closing animation, we cannot reset result directly.
        [self closeAllResultView:^{
            [self resetQueryAndResults];
        }];
    }];

    self.queryView.clearButtonHidden = YES;
}

- (void)copyQueryText {
    [self.inputText ns_copyAndShowToast:YES];
}

- (void)copyFirstTranslatedText {
    if (self.firstService) {
        [self.firstService.result.copiedText ns_copyAndShowToast:YES];
    }
}

- (nullable NSString *)firstTranslatedText {
    if (self.firstService &&
        [self.firstService.result.queryText isEqualToString:self.queryModel.queryText]) {
        NSString *copiedText = self.firstService.result.copiedText;
        if (copiedText.length > 0) {
            return copiedText;
        }
        return self.firstService.result.translatedText;
    }
    return nil;
}

- (void)toggleTranslationLanguages {
    BOOL canSwap = [self.selectLanguageCell canToggleTranslationLanguages];
    BOOL bothAutomatic = [self.queryModel.userSourceLanguage isEqualToString:EZLanguageAuto] &&
        [self.queryModel.userTargetLanguage isEqualToString:EZLanguageAuto];
    if (canSwap || bothAutomatic) {
        BOOL isStreamingInProgress = self.firstService.isStream && !self.firstService.result.isStreamFinished;
        BOOL isResultReady = !self.firstService.result.isLoading && !isStreamingInProgress && !self.firstService.result.error;
        NSString *translatedText = isResultReady ? [self firstTranslatedText] : nil;
        if (bothAutomatic) {
            // Re-query the translation using Auto without changing language preferences.
            if ([translatedText ns_trim].length > 0) {
                self.queryModel.ocrImage = nil;
                [self startQueryText:translatedText actionType:EZActionTypeInputQuery];
            }
            return;
        }

        // Use the completed result's direction; shared language preferences may have changed.
        EZLanguage fromLanguage = self.firstService.result.from;
        EZLanguage toLanguage = self.firstService.result.to;
        BOOL hasReverseDirection = fromLanguage.length > 0 && toLanguage.length > 0 &&
            ![fromLanguage isEqualToString:EZLanguageAuto] &&
            ![toLanguage isEqualToString:EZLanguageAuto] &&
            ![fromLanguage isEqualToString:toLanguage];
        if ([translatedText ns_trim].length > 0 && hasReverseDirection) {
            self.queryModel.userSourceLanguage = fromLanguage;
            self.queryModel.userTargetLanguage = toLanguage;
            self.inputText = translatedText;
            self.queryModel.ocrImage = nil;
            self.queryModel.actionType = EZActionTypeInputQuery;
        }
    }

    [self.selectLanguageCell toggleTranslationLanguages];
}

- (void)stopPlayingQueryText {
    [self togglePlayQueryText:NO];
    [self stopAllResultAudio];
}

- (void)togglePlayQueryText {
    BOOL isPlaying = self.audioPlayer.isPlaying;
    [self togglePlayQueryText:!isPlaying];
}

- (void)togglePlayQueryText:(BOOL)play {
    if (!play) {
        [self.audioPlayer stop];
        return;
    }

    void (^playAudioBlock)(void) = ^{
        NSString *queryText = self.queryText;
        NSString *textLanguage = self.queryModel.queryFromLanguage;
        BOOL isEnglishWord = [queryText isEnglishWordWithLanguage:textLanguage];

        // If query text is an English word, prefer Youdao TTS for its high-quality
        // dictionary recordings. Users on slow or restricted networks can disable
        // this in Advanced settings to fall back to their default TTS service.
        BOOL preferYoudao = self.config.preferYoudaoTTSForEnglishWord;
        EZQueryService *ttsService = (isEnglishWord && preferYoudao) ? self.youdaoService : self.defaultTTSService;
        NSString *accent = self.config.pronunciation == EnglishPronunciationUk ? @"uk" : @"us";

        [self.audioPlayer playTextAudio:queryText
                               language:textLanguage
                                 accent:accent
                               audioURL:nil
                      designatedService:ttsService];
    };

    // Before playing audio, we should detect the query text language.
    if (self.queryModel.hasQueryFromLanguage) {
        playAudioBlock();
    } else {
        [self detectQueryText:^(NSString *_Nonnull language) {
            playAudioBlock();
        }];
    }
}

- (void)stopAllResultAudio {
    [self.inlineLookupContent stopInlineLookupAudio];
    for (EZQueryService *service in self.services) {
        [service.audioPlayer stop];
        [[self resultCellOfResult:service.result].wordResultView stopInlineLookupAudio];
    }
}

/// Update query text, auto adjust ParagraphStyle, and scroll to end of textView.
- (void)updateQueryTextAndParagraphStyle:(NSString *)text actionType:(EZActionType)queryType {
    [self.queryView.textView updateTextAndParagraphStyle:text];
    self.queryModel.actionType = queryType;

    if (text) {
        /**
         If user disabled auto query when getting selected text, we should close tips view after updating query text.
         But reloadTableViewData will lost focus, we need to recover input focus.
         */
        [self showTipsView:NO completion:^{
            [self focusInputTextView];
        }];
    }
}

- (void)updateActionType:(EZActionType)actionType {
    self.queryModel.actionType = actionType;
}

- (void)showTipsView:(BOOL)isVisible {
    [self showTipsView:isVisible content:@"" type:EZTipsCellTypeTextEmpty];
}

- (void)showTipsView:(BOOL)isVisible
             content:(NSString *)content
                type:(EZTipsCellType)type {
    self.tipsCellType = type;
    self.tipsCellContent = content;
    [self.tipsCell updateTipsContent:content type:type];
    [self showTipsView:isVisible completion:nil];
}

- (void)showTipsView:(BOOL)isVisible completion:(void (^)(void))completion {
    // when queryModel.queryText is Empty show tips

    if (!isVisible && !self.isTipsViewVisible) {
        if (completion) {
            completion();
        }
        return;
    }

    self.isTipsViewVisible = isVisible;

    if (isVisible) {
        [self resetQueryAndResults];
    }

    [self reloadTableViewData:completion];
}

- (void)scrollToEndOfTextView {
    [self.queryView scrollToEndOfTextView];
}

- (void)receiveTitlebarAction:(EZTitlebarQuickAction)action {
    switch (action) {
        case EZTitlebarQuickActionWordsSegmentation: {
            self.inputText = [self.inputText segmentWords];
            break;
        }
        case EZTitlebarQuickActionRemoveCommentBlockSymbols: {
            self.inputText = [self.inputText removeCommentBlockSymbols];
            break;
        }
        case EZTitlebarQuickActionReplaceNewlineWithSpace: {
            self.inputText = [self.inputText replacingNewlinesWithWhitespace];
        }
        default:
            break;
    }
}

#pragma mark - Query Methods

- (void)startQueryText {
    [self startQueryText:self.inputText actionType:self.queryModel.actionType];
}

- (void)startQueryWithType:(EZActionType)actionType {
    NSImage *ocrImage = self.queryModel.ocrImage;

    if (ocrImage && (actionType == EZActionTypeOCRQuery || actionType == EZActionTypePasteboardOCR)) {
        BOOL autoQuery = self.config.autoCopyOCRText || self.config.autoQueryPastedText || self.queryModel.autoQuery;
        [self startOCRImage:ocrImage actionType:actionType autoQuery:autoQuery];
    } else {
        [self startQueryText:self.inputText actionType:actionType];
    }
}

/// Directly query model.
- (void)queryCurrentModel {
    if (self.queryText.length == 0) {
        MMLogWarn(@"query text is empty");
        return;
    }

    MMLogInfo(@"query text: %@", self.queryText.truncated);

    // An inline lookup card belongs to the previous query text only.
    [self removeInlineLookupServiceReloadData:NO];

    // !!!: Reset all result before new query.
    [self resetAllResults];

    if (self.queryModel.needDetectLanguage) {
        [self detectQueryText:^(NSString *_Nonnull language) {
            [self queryAllSerives:self.queryModel];
        }];
    } else {
        [self queryAllSerives:self.queryModel];
    }
}

- (void)queryAllSerives:(EZQueryModel *)queryModel {
    MMLogInfo(@"query: %@ --> %@", queryModel.queryFromLanguage, queryModel.queryTargetLanguage);

    self.firstService = nil;
    [self.stoppedPopupServices removeAllObjects];
    [self.popupScrollPositions removeAllObjects];
    [self.incompleteWindowSnapshots removeAllObjects];
    [self updateMainModeWithText:queryModel.queryText language:queryModel.queryFromLanguage];
    if ([self usesTabbedDesign]) {
        EZQueryService *selected = [self serviceWithType:self.selectedPopupServiceID];
        if (!selected || !selected.enabled || !selected.enabledQuery || !selected.enabledAutoQuery || selected.supportedQueryType == EZQueryTextTypeNone) {
            self.selectedPopupServiceID = nil;
            for (EZQueryService *candidate in self.services) {
                if (candidate.enabled && candidate.enabledQuery && candidate.enabledAutoQuery && candidate.supportedQueryType != EZQueryTextTypeNone) {
                    self.selectedPopupServiceID = candidate.serviceTypeWithUniqueIdentifier;
                    break;
                }
            }
            if (!self.selectedPopupServiceID) {
                self.selectedPopupServiceID = self.services.firstObject.serviceTypeWithUniqueIdentifier;
            }
        }
        [self reloadTableViewData:nil];
    }
    for (EZQueryService *service in self.services) {
        BOOL enableAutoQuery = service.enabled && service.enabledQuery && service.enabledAutoQuery && service.supportedQueryType != EZQueryTextTypeNone;
        if (!enableAutoQuery) {
            MMLogInfo(@"service disabled: %@", service.serviceTypeWithUniqueIdentifier);
            continue;
        }

        [self queryWithModel:queryModel service:service];

        if (!self.firstService) {
            self.firstService = service;
            [self autoCopyTranslatedTextOfService:service];
        }
    }

    [[EZLocalStorage shared] increaseQueryCount:self.inputText];
    
    // Add to history
    [QueryRecordManager.shared addRecordWithQueryText:queryModel.queryText
                                         fromLanguage:queryModel.queryFromLanguage
                                           toLanguage:queryModel.queryTargetLanguage
                                                   to:RecordTypeHistory];

    [self updatePopupServiceBar];
    // Auto play query text if it is an English word.
    [self autoPlayEnglishWordAudio];
}

- (void)queryWithModel:(EZQueryModel *)queryModel service:(EZQueryService *)service {
    NSString *queryText = [queryModel.queryText copy];
    [self.incompleteWindowSnapshots removeObject:service.serviceTypeWithUniqueIdentifier];
    BOOL selectedManualQuery = [self usesTabbedDesign] && [self.selectedPopupServiceID isEqualToString:service.serviceTypeWithUniqueIdentifier];
    if ([self usesTabbedDesign] && service != self.inlineLookupService && (service.enabledQuery || selectedManualQuery) && queryText.length) {
        [self.runningPopupServices addObject:service.serviceTypeWithUniqueIdentifier];
    }
    [self queryWithModel:queryModel service:service completion:^(EZQueryResult *result, NSError *_Nullable error) {
        // Ignore callbacks from requests whose model or result has been replaced.
        if ([service isKindOfClass:EZInlineDictService.class] && service != self.inlineLookupService) { return; }
        if (service.queryModel != queryModel || service.result != result) {
            return;
        }
        if (error || !service.isStream || result.isStreamFinished) {
            [self.runningPopupServices removeObject:service.serviceTypeWithUniqueIdentifier];
        }
        if (error) {
            MMLogError(@"service: %@, query error: %@", service.serviceType, error);
        }
        result.error = [EZQueryError queryErrorFrom:error];

        // Auto convert to traditional Chinese if needed.
        if (service.autoConvertTraditionalChinese &&
            [self.queryModel.queryTargetLanguage isEqualToString:EZLanguageTraditionalChinese]) {
            [service.result convertToTraditionalChineseResult];
        }

        BOOL hideResult = !result.manualShow && !result.hasTranslatedResult && result.isWarningErrorType;
        if (hideResult) {
            result.isShowing = NO;
        }

        //        MMLogInfo(@"update service: %@, %@", service.serviceType, result);
        [self updateCellWithResult:result reloadData:YES];

        // Backfill history record with the first service's translated text.
        if (service == self.firstService) {
            BOOL shouldRecord = !service.isStream || result.isStreamFinished;
            if (shouldRecord && result.translatedText.length > 0) {
                [QueryRecordManager.shared updateTranslatedResult:result.translatedText
                                                      forQueryText:queryText
                                                                in:RecordTypeHistory];
            }

            // Append the query to the vocabulary notebook when it has content.
            BOOL hasContent = queryText.length > 0
                && (result.wordResult != nil || result.translatedText.length > 0);
            if (shouldRecord && hasContent && result.error == nil) {
                [VocabularyNotebookService.shared appendWithQueryModel:queryModel result:result trigger:nil];
            }
        }

        // Inline dictionary cards are recorded too, marked `inline`: clicking a word
        // inside a result says "I don't know this one", which the first service's
        // record above cannot express. The inline service is never `firstService`,
        // so without this branch the click is lost.
        if (service == self.inlineLookupService) {
            BOOL shouldRecord = !service.isStream || result.isStreamFinished;
            BOOL hasContent = queryText.length > 0
                && (result.wordResult != nil || result.translatedText.length > 0);
            if (shouldRecord && hasContent && result.error == nil) {
                [VocabularyNotebookService.shared appendWithQueryModel:queryModel result:result trigger:@"inline"];
            }
        }

        if (service.autoCopyTranslatedTextBlock) {
            BOOL shouldAutoCopy = !service.isStream || result.isStreamFinished;
            if (shouldAutoCopy) {
                service.autoCopyTranslatedTextBlock(result, error);
            }
        }
    }];
    [self updatePopupServiceBar];
}

// TODO: service already has the model property.
- (void)queryWithModel:(EZQueryModel *)queryModel
               service:(EZQueryService *)service
            completion:(nonnull void (^)(EZQueryResult *result, NSError *_Nullable error))completion {
    BOOL selectedManualQuery = [self usesTabbedDesign] && [self.selectedPopupServiceID isEqualToString:service.serviceTypeWithUniqueIdentifier];
    if (!service.enabledQuery && !selectedManualQuery) {
        MMLogWarn(@"service disabled: %@", service.serviceTypeWithUniqueIdentifier);
        return;
    }
    if (queryModel.queryText.length == 0) {
        MMLogWarn(@"queryText is empty");
        return;
    }

    //    MMLogInfo(@"query service: %@", service.serviceType);

    EZQueryResult *result = service.result;

    // Show result if it has been queried.
    result.isShowing = YES;
    result.isLoading = YES;

    [self updateResultLoadingAnimation:result];

    [service startQueryStream:queryModel completionHandler:completion];

    [EZLocalStorage.shared increaseQueryService:service];
}

- (void)updateResultLoadingAnimation:(EZQueryResult *)result {
    EZResultView *resultView = [self resultCellOfResult:result];
    [resultView updateLoadingAnimation];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [self displayedServices].count + [self resultCellOffset];
}

#pragma mark - NSTableViewDelegate

// View-base 设置某个元素的具体视图
- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    //    MMLogInfo(@"tableView for row: %ld", row);

    if ([self isInputFieldCellAtRow:row]) {
        self.queryView = [self createQueryView];
        self.queryView.associatedWindowType = self.windowType;
        [self.queryView initializeAimatedButtonAlphaValue:self.queryModel];
        self.queryView.queryModel = self.queryModel;
        return self.queryView;
    }

    if ([self isSelectLanguageCellAtRow:row]) {
        return [self createSelectLanguageCell];
    }

    // show tips view
    if ([self isTipsViewAtRow:row]) {
        EZTableTipsCell *tipsCell = [self.tableView makeViewWithIdentifier:EZTableTipsCellId owner:self];
        if (!tipsCell) {
            tipsCell = [[EZTableTipsCell alloc] initWithFrame:[self tableViewContentBounds]
                                                         type:self.tipsCellType
                                                      content:self.tipsCellContent];
            tipsCell.identifier = EZTableTipsCellId;
        }
        self.tipsCell = tipsCell;
        return tipsCell;
    }

    if ([self isPopupServiceBarAtRow:row]) {
        [self updatePopupServiceBar];
        return self.popupServiceBar;
    }

    EZResultView *resultCell = [self resultCellAtRow:row];
    resultCell.associatedWindowType = self.windowType;

    return resultCell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[EZTableRowView alloc] init];
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    CGFloat height;

    if ([self isInputFieldCellAtRow:row]) {
        height = self.queryModel.queryViewHeight;
    } else if ([self isSelectLanguageCellAtRow:row]) {
        height = 35;
    } else if ([self isTipsViewAtRow:row]) {
        if (!self.tipsCell) {
            // mini cell height
            if ([self isCustomTipsType]) {
                height = 80;
            } else {
                height = 104;
            }
        } else {
            height = [self.tipsCell cellHeight];
        }
    } else if ([self isPopupServiceBarAtRow:row]) {
        height = self.popupServiceBar.preferredHeight ?: 32;
    } else {
        EZQueryResult *result = [self serviceAtRow:row].result;
        if ([self usesTabbedDesign]) {
            height = (result.queryText.length || result.hasShowingResult || result.isLoading)
                ? MAX(result.viewHeight, 38) : 1;
        } else if (result.isShowing) {
            // A non-zero value must be set, but the initial viewHeight is 0.
            height = MAX(result.viewHeight, EZResultViewMiniHeight);
        } else {
            height = EZResultViewMiniHeight;
        }
    }
    //    MMLogInfo(@"row: %ld, height: %@", row, @(height));

    return height;
}

// Disable select cell
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return NO;
}


#pragma mark - Update TableView and row cell.

/// Reset tableView, reloadData
- (void)resetTableView:(nullable void (^)(void))completion {
    [self resetQueryAndResults];
    [self reloadTableViewData:completion];
}

/// TableView reloadData, and update window height.
- (void)reloadTableViewData:(nullable void (^)(void))completion {
    [self reloadTableViewDataWithLock:YES completion:completion];
}

- (void)reloadTableViewDataWithLock:(BOOL)lockFlag completion:(nullable void (^)(void))completion {
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [self updateWindowHeightWithLock:lockFlag];
        if (completion) {
            completion();
        }
    }];

    [self updatePopupServiceBar];
    [self.tableView reloadData];
    [CATransaction commit];
}

/// Reload table view only. Caller is responsible for window height updates.
- (void)reloadTableViewDataWithoutWindowHeightUpdate:(nullable void (^)(void))completion {
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (completion) {
            completion();
        }
    }];

    [self updatePopupServiceBar];
    [self.tableView reloadData];
    [CATransaction commit];
}

- (void)closeAllResultView:(void (^)(void))completionHandler {
    [self.queryModel stopAllService];

    // !!!: Need to update all result cells, even it's not showing, it may show error image.
    NSArray *allResults = [self resetAllResults];
    [self updateCellWithResults:allResults reloadData:YES completionHandler:completionHandler];
}


- (void)updateCellWithResult:(EZQueryResult *)result reloadData:(BOOL)reloadData {
    if (result) {
        [self updateCellWithResults:@[ result ] reloadData:reloadData completionHandler:nil];
    }
}

- (void)updateCellWithResult:(EZQueryResult *)result reloadData:(BOOL)reloadData completionHandler:(void (^)(void))completionHandler {
    [self updateCellWithResults:@[ result ] reloadData:reloadData completionHandler:completionHandler];
}

- (void)updateCellWithResults:(NSArray<EZQueryResult *> *)results reloadData:(BOOL)reloadData {
    [self updateCellWithResults:results reloadData:reloadData completionHandler:nil];
}

- (void)updateCellWithResults:(NSArray<EZQueryResult *> *)results reloadData:(BOOL)reloadData completionHandler:(void (^)(void))completionHandler {
    NSMutableIndexSet *rowIndexes = [NSMutableIndexSet indexSet];
    BOOL hasTableResults = NO;
    for (EZQueryResult *result in results) {
        if (self.inlineLookupPopover && result == self.inlineLookupService.result) {
            result.isLoading = NO;
            dispatch_block_on_main_safely(^{ [self updateInlineLookupPopover]; });
            continue;
        }
        hasTableResults = YES;
        // !!!: Render webView html takes a little time(~0.5s), so we stop loading when webView finished loading.
        BOOL isFinished = YES;
        if (result.isShowing && result.htmlString.length) {
            isFinished = result.webViewManager.wordResultViewHeight > 0;
        }
        result.isLoading = !isFinished;

        NSIndexSet *indexSet = [self indexSetOfResult:result];
        if (indexSet) {
            [rowIndexes addIndexes:indexSet];
        }
    }
    if (hasTableResults) {
        [self updateTableViewRowIndexes:rowIndexes reloadData:reloadData completionHandler:completionHandler];
    } else if (completionHandler) {
        dispatch_block_on_main_safely(completionHandler);
    }
}

- (void)updateTableViewRowIndexes:(NSIndexSet *)rowIndexes reloadData:(BOOL)reloadData {
    [self updateTableViewRowIndexes:rowIndexes reloadData:reloadData completionHandler:nil];
}

/// Update tableView row data, update row height and window height with animation.
- (void)updateTableViewRowIndexes:(NSIndexSet *)rowIndexes reloadData:(BOOL)reloadData completionHandler:(void (^)(void))completionHandler {
    [self updateTableViewRowIndexes:rowIndexes reloadData:reloadData animate:YES completionHandler:completionHandler];
}

/// Update cell row height, and reload cell data with animation.
/// TODO: we need to optimize the way of updating row height.
- (void)updateTableViewRowIndexes:(NSIndexSet *)rowIndexes
                       reloadData:(BOOL)reloadData
                          animate:(BOOL)animateFlag
                completionHandler:(void (^)(void))completionHandler {
    //    MMLogInfo(@"updateTableViewRowIndexes: %@", rowIndexes);

    // !!!: Since the caller may be in non-main thread, we need to dispatch to main thread, but canont always use dispatch_async, it will cause the animation not smooth.
    dispatch_block_on_main_safely(^{
        [self updatePopupServiceBar];
        if (reloadData) {
            // !!!: Note: For NSView-based table views, this method drops the view-cells in the table row, but not the NSTableRowView instances.

            // ???: need to check.

            [self.tableView reloadDataForRowIndexes:rowIndexes columnIndexes:[NSIndexSet indexSetWithIndex:0]];
        }

        CGFloat duration = animateFlag ? EZUpdateTableViewRowHeightAnimationDuration : 0;

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *_Nonnull context) {
            context.duration = duration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

            // !!!: Must first notify the update tableView cell height, and then calculate the tableView height.
            //            MMLogInfo(@"noteHeightOfRowsWithIndexesChanged: %@", rowIndexes);
            [self.tableView noteHeightOfRowsWithIndexesChanged:rowIndexes];
            [self updateWindowHeight];
        } completionHandler:^{
            //            MMLogInfo(@"completionHandler, updateTableViewRowIndexes: %@", rowIndexes);
            if (completionHandler) {
                completionHandler();
            }
        }];
    });
}

- (void)updateQueryCell {
    [self updateQueryCellWithAnimation:NO completionHandler:nil];
}

- (void)updateQueryCellWithAnimation:(BOOL)animateFlag {
    [self updateQueryCellWithAnimation:animateFlag completionHandler:nil];
}

/// Update query cell data and row height.
- (void)updateQueryCellWithCompletionHandler:(nullable void (^)(void))completionHandler {
    [self updateQueryCellWithAnimation:YES completionHandler:completionHandler];
}

- (void)updateQueryCellWithAnimation:(BOOL)animateFlag completionHandler:(nullable void (^)(void))completionHandler {
    if (self.windowType == EZWindowTypeMain) {
        self.mainSurface.sourceHeight = [self.queryView heightOfQueryView];
        [self.view layoutSubtreeIfNeeded];
        [self.queryView setNeedsUpdateConstraints:YES];
        [self updateWindowHeight];
        if (completionHandler) { completionHandler(); }
        return;
    }
    if (self.isInputFieldCellVisible) {
        NSIndexSet *firstIndexSet = [NSIndexSet indexSetWithIndex:self.inputFieldCellIndex];
        [self updateTableViewRowIndexes:firstIndexSet reloadData:NO animate:animateFlag completionHandler:completionHandler];
    }
}

- (void)updateSelectLanguageCell {
    if ([self embedsPopupLanguageHeader]) {
        self.selectLanguageCell.queryModel = self.queryModel;
        return;
    }
    if (self.isSelectLanguageCellVisible) {
        NSIndexSet *rowIndexes = [NSMutableIndexSet indexSetWithIndex:self.selectLanguageCellIndex];
        [self.tableView reloadDataForRowIndexes:rowIndexes columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}


// iterate all result cell, if cell height is not equal to the result cell height, update cell height.
- (void)updateAllResultCellHeightIfNeed {
    NSInteger offset = [self resultCellOffset];
    NSInteger numberOfRows = [self.tableView numberOfRows];
    for (NSInteger row = offset; row < numberOfRows; row++) {
        EZQueryService *service = [self serviceAtRow:row];
        EZQueryResult *result = service.result;
        if (result) {
            EZResultView *resultCell = [[[self.tableView rowViewAtRow:row makeIfNecessary:NO] subviews] firstObject];
            CGFloat cellHeight = resultCell.height;
            CGFloat resultHeight = result.viewHeight;
            if (cellHeight != resultHeight) {
                [self updateResultCellHeight:result];
            }
        }
    }
}

- (void)updateTableViewHeight {
    if ([self usesTabbedDesign] && self.queryView && self.isInputFieldCellVisible) {
        self.queryModel.queryViewHeight = [self.queryView heightOfQueryView];
    }
    NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self.tableView numberOfRows])];
    [self.tableView noteHeightOfRowsWithIndexesChanged:indexSet];
}

- (void)updateResultCellHeight:(EZQueryResult *)result {
    NSIndexSet *indexSet = [self indexSetOfResult:result];
    if (indexSet) {
        [self.tableView noteHeightOfRowsWithIndexesChanged:indexSet];
    }
}

- (nullable NSIndexSet *)indexSetOfResult:(EZQueryResult *)result {
    NSInteger row = [self rowIndexOfResult:result];
    if (row == NSNotFound) {
        return nil;
    }
    NSInteger index = row + [self resultCellOffset];
    return [NSIndexSet indexSetWithIndex:index];
}

/// !!!: Maybe return NSNotFound
- (NSUInteger)rowIndexOfResult:(EZQueryResult *)result {
    NSString *serviceTypeWithUniqueIdentifier = result.serviceTypeWithUniqueIdentifier;
    // Sometimes the query is very slow, and at that time the user may have turned off the service in the settings page.
    return [[self displayedServices] indexOfObjectPassingTest:^BOOL(EZQueryService *service, NSUInteger index, BOOL *stop) {
        return [service.serviceTypeWithUniqueIdentifier isEqualToString:serviceTypeWithUniqueIdentifier];
    }];
}


- (void)resetCellWithService:(EZQueryService *)service autoQuery:(BOOL)autoQuery {
    [self resetService:service];

    EZQueryResult *newResult = [service resetServiceResult];

    [self updateCellWithResult:newResult reloadData:YES completionHandler:^{
        if (autoQuery) {
            // Make enabledQuery = YES before retry, it may be closed manually.
            if (![self usesTabbedDesign]) {
                service.enabledQuery = YES;
            }

            [self queryWithModel:self.queryModel service:service];
        }
    }];
}

- (void)resetService:(EZQueryService *)service {
    // We need to set service.queryModel first, otherwise result.queryModel will be nil.
    service.queryModel = self.queryModel;
    [service resetServiceResult];
    service.windowType = self.windowType;
}

- (void)updateService:(NSString *)serviceTypeWithUniqueIdentifier autoQuery:(BOOL)autoQuery {
    NSMutableArray *newServices = [self.services mutableCopy];
    for (EZQueryService *service in self.services) {
        if ([service.serviceTypeWithUniqueIdentifier isEqualToString:serviceTypeWithUniqueIdentifier]) {
            if (!autoQuery) {
                [self updateCellWithResult:service.result reloadData:YES completionHandler:nil];
                return;
            }

            EZQueryService *updatedService = [EZLocalStorage.shared service:serviceTypeWithUniqueIdentifier windowType:self.windowType];
            if (!updatedService) {
                return;
            }

            // For some strange reason, the old service can not be deallocated, this will cause a memory leak, and we also need to cancel old services subscribers.
            if ([service isKindOfClass:EZStreamService.class]) {
                [((EZStreamService *)service) cancelSubscribers];
            }

            NSInteger index = [self.serviceTypeIds indexOfObject:serviceTypeWithUniqueIdentifier];
            newServices[index] = updatedService;
            self.services = newServices.copy;

            [self resetCellWithService:updatedService autoQuery:autoQuery];

            return;
        }
    }
}

- (void)resetAllCellWithServices:(NSArray *)allServices completion:(void (^)(void))completion {
    [self setupServices:allServices];
    [self reloadTableViewData:completion];
}

/// Get latest services from local storage.
- (NSArray<EZQueryService *> *)latestServices {
    return [EZLocalStorage.shared enabledServices:self.windowType];
}


#pragma mark - Update Data.

- (void)resetQueryAndResults {
    [self resetAllResults];

    if (self.inputText.length) {
        self.inputText = @"";
    }
}

- (NSArray<EZQueryResult *> *)resetAllResults {
    [self.runningPopupServices removeAllObjects];
    NSMutableArray *allResults = [NSMutableArray array];
    for (EZQueryService *service in self.services) {
        EZQueryResult *result = [service resetServiceResult];
        [allResults addObject:result];
    }
    return allResults;
}

- (void)discardDictionaryWebViews {
    for (EZQueryService *service in self.services) {
        EZQueryResult *result = service.result;
        if (!EZResultNeedsDictionaryHTMLHeight(result)) {
            continue;
        }

        EZResultView *resultCell = [self resultCellOfResult:result];
        [resultCell.wordResultView.webView removeFromSuperview];
        resultCell.wordResultView.webView = nil;
        [result.webViewManager discardReusableWebView];
    }
}

- (nullable EZResultView *)resultCellOfResult:(EZQueryResult *)result {
    NSInteger index = [self rowIndexOfResult:result];
    if (index != NSNotFound) {
        NSInteger row = index + [self resultCellOffset];
        EZResultView *resultCell = [[[self.tableView rowViewAtRow:row makeIfNecessary:NO] subviews] firstObject];

        // ???: Why is it possible to return a EZSelectLanguageCell ?
        if ([resultCell isKindOfClass:[EZResultView class]]) {
            return resultCell;
        }
    }

    return nil;
}

- (void)updateResultCell:(EZQueryResult *)result {
    EZResultView *resultView = [self resultCellOfResult:result];
    resultView.result = result;
}

- (void)delayDetectQueryText {
    [self cancelDelayDetectQueryText];
    [self performSelector:@selector(detectQueryText:) withObject:nil afterDelay:EZDelayDetectTextLanguageInterval];
}

- (void)cancelDelayDetectQueryText {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(detectQueryText:) object:nil];
}

/// Detect query text, and update select language cell.
- (void)detectQueryText:(nullable void (^)(NSString *language))completion {
    [self cancelDelayDetectQueryText];

    NSString *queryText = self.queryText ?: @"";
    [self.detectManager detectText:queryText completion:^(EZQueryModel *queryModel, NSError *error) {
        // Language detection is async, so ignore callbacks for an older query.
        NSString *currentQueryText = self.queryText ?: @"";
        if (self.queryModel != queryModel || ![currentQueryText isEqualToString:queryText]) {
            return;
        }
        // `self.queryModel.detectedLanguage` has already been updated inside the method.

        // Show detected language button if has queryText, even detect language is auto.
        BOOL showAutoLanguage = YES;
        if (self.queryText.length == 0) {
            showAutoLanguage = NO;
        }
        self.queryModel.showAutoLanguage = showAutoLanguage;

        [self updateQueryViewModelAndDetectedLanguage:queryModel];

        if (completion) {
            completion(queryModel.detectedLanguage);
        }
    }];
}

- (void)updateQueryViewModelAndDetectedLanguage:(EZQueryModel *)queryModel {
    self.queryView.clearButtonHidden = (queryModel.inputText.length == 0) && ([self allShowingResults].count == 0);

    self.queryView.queryModel = queryModel;
    [self updateQueryCell];
    [self updateSelectLanguageCell];
    [self updatePopupServiceBar];
}


// TODO: need to check, use true cell result, rather than self result
- (NSArray *)allShowingResults {
    NSMutableArray *results = [NSMutableArray array];
    for (EZQueryService *service in self.services) {
        EZQueryResult *result = service.result;
        if (result.isShowing) {
            [results addObject:result];
        }
    }

    return results;
}

/// Just set result isShowing to NO, not update cell view.
- (void)closeAllShowingResults {
    NSArray *results = [self allShowingResults];
    for (EZQueryResult *result in results) {
        result.isShowing = NO;
        result.isLoading = NO;
    }
}

/// Set all result webViewManager.isLoad to NO
- (void)setNeedUpdateIframeHeightForAllResults {
    for (EZQueryService *service in self.services) {
        EZQueryResult *result = service.result;
        result.webViewManager.needUpdateIframeHeight = YES;
    }
}

- (void)disableReplaceTextButton {
    for (EZQueryService *service in self.services) {
        service.result.showReplaceButton = NO;

        EZResultView *resultView = [self resultCellOfResult:service.result];
        resultView.wordResultView.replaceTextButton.enabled = NO;
    }
}


#pragma mark - Set up cell view

- (EZSelectLanguageCell *)createSelectLanguageCell {
    EZSelectLanguageCell *selectLanguageCell = [self embedsPopupLanguageHeader] && self.windowType == EZWindowTypeMain
        ? self.selectLanguageCell : [self.tableView makeViewWithIdentifier:EZSelectLanguageCellId owner:self];
    if (!selectLanguageCell) {
        selectLanguageCell = [[EZSelectLanguageCell alloc] initWithFrame:[self tableViewContentBounds]];
        selectLanguageCell.identifier = EZSelectLanguageCellId;
    }
    selectLanguageCell.popupStyle = [self usesTabbedDesign];
    selectLanguageCell.queryModel = self.queryModel;
    self.selectLanguageCell = selectLanguageCell;

    mm_weakify(self);
    [selectLanguageCell setEnterActionBlock:^(EZLanguage from, EZLanguage to) {
        mm_strongify(self);
        self.queryModel.userSourceLanguage = from;
        self.queryModel.userTargetLanguage = to;

        [self retryQueryWithLanguage:EZLanguageAuto];
    }];
    [selectLanguageCell setToggleTranslationLanguagesBlock:^{
        mm_strongify(self);
        [self toggleTranslationLanguages];
    }];
    return selectLanguageCell;
}

- (EZQueryView *)createQueryView {
    EZQueryView *queryView = self.windowType == EZWindowTypeMain
        ? self.queryView : [self.tableView makeViewWithIdentifier:EZQueryViewId owner:self];
    if (!queryView) {
        queryView = [[EZQueryView alloc] initWithFrame:[self tableViewContentBounds]];
        queryView.identifier = EZQueryViewId;
    }

    // placeholder, just for new user.
    NSString *placeholderText = NSLocalizedString(@"placeholder", nil);
    if (EZLocalStorage.shared.queryCount > 100) {
        placeholderText = @"";
    }
    queryView.placeholderText = placeholderText;
    queryView.popupStyle = [self usesTabbedDesign];
    // Main input is bounded by its pane, never by the height of the text.
    queryView.expandedInput = self.windowType == EZWindowTypeMain;
    if (self.windowType == EZWindowTypeMain) {
        queryView.textView.verticallyResizable = YES;
        queryView.textView.horizontallyResizable = NO;
        queryView.textView.autoresizingMask = NSViewWidthSizable;
        queryView.textView.textContainer.widthTracksTextView = YES;
        queryView.textView.textContainer.heightTracksTextView = NO;
        queryView.textView.textContainer.containerSize = NSMakeSize(queryView.textView.width, CGFLOAT_MAX);
    }
    queryView.languageHeaderView = [self embedsPopupLanguageHeader] ? [self createSelectLanguageCell] : nil;

    queryView.audioButton.audioPlayer = self.audioPlayer;

    mm_weakify(self);
    [queryView setUpdateInputTextBlock:^(NSString *text, CGFloat queryViewHeight) {
        mm_strongify(self);
        //        MMLogInfo(@"UpdateQueryTextBlock");

        // !!!: The code here is a bit messy, so you need to be careful about changing it.

        // But, since there are cases where the query text is set manually, such as query selected text, where the query text is set first and then the input text is modified, the query cell must be updated for such cases.

        // Reduce the update frequency, update only when the queryText or height changes.
        if ([self.inputText isEqualToString:text] && self.queryModel.queryViewHeight == queryViewHeight) {
            return;
        }

        NSString *oldInputText = self.inputText;
        self.inputText = text;

        // Only detect when query text is changed.
        if (![[self.inputText  ns_trim] isEqualToString:[oldInputText  ns_trim]]) {
            [self delayDetectQueryText];
        }

        self.queryModel.queryViewHeight = queryViewHeight;
        [self updateQueryCell];
    }];

    [queryView setEnterActionBlock:^(NSString *text) {
        mm_strongify(self);
        // tips view hidden once user tap entry
        self.isTipsViewVisible = NO;
        [self startQueryText:text];
    }];

    [queryView setPasteTextBlock:^(NSString *_Nonnull text) {
        mm_strongify(self);
        BOOL autoQuery = [MyConfiguration.shared autoQueryPastedText];
        if (autoQuery) {
            [self startQueryText:text];
        }
    }];

    [queryView setPlayAudioBlock:^(NSString *text) {
        mm_strongify(self);
        [self togglePlayQueryText];
    }];

    [queryView setCopyTextBlock:^(NSString *text) {
        [text ns_copyAndShowToast:YES];
    }];

    [queryView setClearBlock:^(NSString *_Nonnull text) {
        mm_strongify(self);

        // Close tips view  when user clicking clear button.
        self.isTipsViewVisible = NO;

        [self clearAll];
    }];

    [queryView setSelectedLanguageBlock:^(EZLanguage language) {
        mm_strongify(self);

        EZLanguage detectedLanguage = self.queryModel.detectedLanguage;
        if (![detectedLanguage isEqualToString:language]) {
            self.queryModel.detectedLanguage = language;
            [self retryQueryWithLanguage:language];

            [self updateSelectLanguageCell];

            NSDictionary *dict = @{
                @"autoDetect" : detectedLanguage,
                @"userSelect" : language,
            };
            [EZAnalyticsService logEventWithName:@"change_detected_language" parameters:dict];
        }
    }];

    return queryView;
}

- (EZResultView *)resultCellAtRow:(NSInteger)row {
    EZQueryService *service = [self serviceAtRow:row];
    EZResultView *resultCell = [self.tableView makeViewWithIdentifier:EZResultViewId owner:self];

    if (!resultCell) {
        resultCell = [[EZResultView alloc] initWithFrame:[self tableViewContentBounds]];
        resultCell.identifier = EZResultViewId;
    }

    NSSize cellSize = resultCell.frame.size;
    cellSize.width = [self tableViewContentBounds].size.width;
    [resultCell setFrameSize:cellSize];
    EZQueryResult *result = service.result;
    resultCell.associatedWindowType = self.windowType;
    resultCell.popupStyle = [self usesTabbedDesign];
    resultCell.inlineCard = (service == self.inlineLookupService);
    if ([self usesTabbedDesign] && (result.queryText.length || result.hasShowingResult || result.isLoading)) {
        result.isShowing = YES;
    }
    resultCell.service = service;
    resultCell.result = result;
    [self setupResultCell:resultCell];

    WKWebView *webView = nil;
    if ([service.serviceType isEqualToString:EZServiceTypeAppleDictionary]) {
        EZWebViewManager *webViewManager = result.webViewManager;
        BOOL shouldRenderHTML = EZResultShouldRenderDictionaryHTML(result);
        BOOL htmlChanged = ![webViewManager.loadedHTMLString isEqualToString:result.htmlString];
        BOOL needLoadHTML = shouldRenderHTML && (!webViewManager.isLoaded || htmlChanged);
        BOOL needUpdateIframe = shouldRenderHTML && webViewManager.needUpdateIframeHeight && webViewManager.isLoaded;
        if (needLoadHTML || needUpdateIframe) {
            webView = webViewManager.webView;
            resultCell.wordResultView.webView = webView;
        }

        if (needLoadHTML) {
            NSUInteger renderGeneration = [webViewManager beginRenderingHTML];
            webViewManager.isLoaded = YES;
            webViewManager.loadedHTMLString = result.htmlString;
            WKNavigation *navigation = [webView loadHTMLString:result.htmlString baseURL:nil];
            [webViewManager trackRenderingNavigation:navigation renderGeneration:renderGeneration];
        } else if (needUpdateIframe) {
            [webViewManager updateAllIframe];
        }
    } else if ([service.serviceType isEqualToString:EZServiceTypeMDict]) {
        EZWebViewManager *webViewManager = result.webViewManager;
        BOOL shouldRenderHTML = EZResultShouldRenderDictionaryHTML(result);
        BOOL htmlChanged = ![webViewManager.loadedHTMLString isEqualToString:result.htmlString];
        BOOL needLoadHTML = shouldRenderHTML && (!webViewManager.isLoaded || htmlChanged);
        BOOL needUpdateIframe = shouldRenderHTML && webViewManager.needUpdateIframeHeight && webViewManager.isLoaded;
        if (needLoadHTML || needUpdateIframe) {
            webView = webViewManager.webView;
            webView.appearance = nil;
            resultCell.wordResultView.webView = webView;
        }

        if (needLoadHTML) {
            NSUInteger renderGeneration = [webViewManager beginRenderingHTML];
            webViewManager.isLoaded = YES;
            webViewManager.loadedHTMLString = result.htmlString;
            WKNavigation *navigation = [webView loadHTMLString:result.htmlString baseURL:nil];
            [webViewManager trackRenderingNavigation:navigation renderGeneration:renderGeneration];
        } else if (needUpdateIframe) {
            [webViewManager updateAllIframe];
        }
    }

    return resultCell;
}

/// Configure callbacks for a reusable result cell.
- (void)setupResultCell:(EZResultView *)resultView {
    EZQueryResult *result = resultView.result;
    if (!result.serviceTypeWithUniqueIdentifier) {
        return;
    }
    EZQueryService *service = [self serviceWithType:result.serviceTypeWithUniqueIdentifier];
    if (!service) {
        return;
    }

    mm_weakify(self);
    [resultView setQueryTextBlock:^(NSString *_Nonnull word) {
        mm_strongify(self);
        [self startQueryText:word];
    }];

    [resultView setInlineLookupBlock:^(NSString *_Nonnull word, NSTextView *_Nonnull anchor, NSRange range) {
        mm_strongify(self);
        [self toggleInlineLookupForWord:word afterService:service anchor:anchor range:range];
    }];

    [resultView setRetryBlock:^(EZQueryResult *result) {
        mm_strongify(self);
        [self.stoppedPopupServices removeObject:service.serviceTypeWithUniqueIdentifier];
        [self resetCellWithService:service autoQuery:YES];
    }];

    // Do not capture `result`; the block receives the current result instance.
    [resultView setClickArrowBlock:^(EZQueryResult *newResult) {
        mm_strongify(self);
        if (service == self.inlineLookupService) {
            [self removeInlineLookupServiceReloadData:YES];
            return;
        }
        BOOL isShowing = newResult.isShowing;

        if (!isShowing) {
            [service.audioPlayer stop];
        }

        service.enabledQuery = isShowing;
        [self handleArrowToggleForResult:newResult service:service isShowing:isShowing];
    }];
}

#pragma mark - Result Arrow Toggle

/// Route an arrow toggle to refresh, query, or redraw the result cell.
- (void)handleArrowToggleForResult:(EZQueryResult *)result
                            service:(EZQueryService *)service
                          isShowing:(BOOL)isShowing {
    NSString *currentQueryText = self.queryModel.queryText ?: @"";
    NSString *resultQueryText = result.queryText ?: @"";

    // Expanded cells can still hold rendered content from an older query.
    BOOL hasStaleExpandedResult = isShowing
        && result.hasShowingResult
        && ![resultQueryText isEqualToString:currentQueryText];

    if (hasStaleExpandedResult) {
        [self performAfterLanguageDetectionIfNeeded:^{
            [self requeryStaleExpandedResultIfToggleStillValid:result
                                                       service:service
                                                     queryText:currentQueryText];
        }];
        return;
    }

    // Newly expanded services with no visible result should query this text.
    BOOL needsQueryForExpandedService = isShowing && !result.hasShowingResult;
    if (needsQueryForExpandedService) {
        [self performAfterLanguageDetectionIfNeeded:^{
            [self queryExpandedServiceIfToggleStillValid:service
                                                  result:result
                                               queryText:currentQueryText];
        }];
        return;
    }

    // Existing matching results only need their expanded/collapsed state redrawn.
    [self updateCellWithResult:result reloadData:YES];
}

/// Check that a delayed arrow action still targets the same service, result, and query.
- (BOOL)isArrowToggleStillValidForService:(EZQueryService *)service
                                   result:(EZQueryResult *)result
                                queryText:(NSString *)queryText {
    // Language detection may finish after input changes or service reloads.
    EZQueryService *currentService = [self serviceWithType:service.serviceTypeWithUniqueIdentifier];
    NSString *currentQueryText = self.queryModel.queryText ?: @"";
    return currentService == service
        && service.result == result
        && (![self usesTabbedDesign] || [self.selectedPopupServiceID isEqualToString:service.serviceTypeWithUniqueIdentifier])
        && (![self usesTabbedDesign] || ![self.runningPopupServices containsObject:service.serviceTypeWithUniqueIdentifier])
        && result.isShowing
        && [currentQueryText isEqualToString:queryText];
}

/// Run the action after language detection when the query still needs it.
- (void)performAfterLanguageDetectionIfNeeded:(void (^)(void))action {
    if (!self.queryModel.needDetectLanguage) {
        action();
        return;
    }

    [self detectQueryText:^(NSString *_Nonnull language) {
        action();
    }];
}

/// Reset stale expanded content and query again if the toggle is still valid.
- (void)requeryStaleExpandedResultIfToggleStillValid:(EZQueryResult *)result
                                             service:(EZQueryService *)service
                                           queryText:(NSString *)queryText {
    if (![self isArrowToggleStillValidForService:service result:result queryText:queryText]) {
        return;
    }

    // Another callback may have cleared or replaced the stale result already.
    if (!result.hasShowingResult) {
        return;
    }

    NSString *resultQueryText = result.queryText ?: @"";
    if ([resultQueryText isEqualToString:queryText]) {
        return;
    }

    // Remove stale HTML before auto-querying the expanded service again.
    [self resetCellWithService:service autoQuery:YES];
}

/// Query an expanded empty service if the toggle still targets this query.
- (void)queryExpandedServiceIfToggleStillValid:(EZQueryService *)service
                                        result:(EZQueryResult *)result
                                     queryText:(NSString *)queryText {
    if (![self isArrowToggleStillValidForService:service result:result queryText:queryText]) {
        return;
    }

    // Another callback may have produced a result while detection was running.
    if (result.hasShowingResult) {
        return;
    }

    // A no-result expanded cell should query only after the guard passes.
    [self queryWithModel:self.queryModel service:service];
}

#pragma mark - Row Mapping

#pragma mark - Inline word lookup

/// Opens a word lookup without replacing the parent query or scrolling its result.
- (void)toggleInlineLookupForWord:(NSString *)word afterService:(EZQueryService *)sourceService
                         anchor:(NSTextView *)anchor range:(NSRange)range {
    NSString *trimmedWord = [word stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmedWord.length) {
        return;
    }

    BOOL isSameWord = [self.inlineLookupWord isEqualToString:trimmedWord];
    [self removeInlineLookupServiceReloadData:NO];
    if (isSameWord) {
        if (![self usesTabbedDesign]) { [self reloadTableViewData:nil]; }
        return;
    }

    // Query the word with its own model so the main query text stays intact.
    EZQueryModel *wordModel = [self.queryModel copy];
    wordModel.inputText = trimmedWord;
    wordModel.needDetectLanguage = NO;

    EZInlineDictService *service = [[EZInlineDictService alloc] init];
    service.windowType = self.windowType;
    service.enabledQuery = YES;
    service.queryModel = wordModel;

    // Materialize the independent result before presenting the word card.
    [service resetServiceResult];

    NSUInteger sourceIndex = [self.services indexOfObject:sourceService];
    NSUInteger insertIndex = (sourceIndex == NSNotFound) ? self.services.count : sourceIndex + 1;

    NSMutableArray *services = [self.services mutableCopy];
    NSMutableArray *serviceTypeIds = [self.serviceTypeIds mutableCopy];
    [services insertObject:service atIndex:insertIndex];
    [serviceTypeIds insertObject:[service serviceTypeWithUniqueIdentifier] atIndex:insertIndex];
    self.services = services;
    self.serviceTypeIds = serviceTypeIds;

    self.inlineLookupService = service;
    self.inlineLookupWord = trimmedWord;

    mm_weakify(self);
    void (^startLookup)(void) = ^{
        mm_strongify(self);
        if (self.inlineLookupService != service) { return; }
        [self queryWithModel:wordModel service:service];
        EZLanguage language = [trimmedWord isEnglishWordWithLanguage:EZLanguageEnglish]
            ? EZLanguageEnglish : wordModel.queryFromLanguage;
        [service.audioPlayer playTextAudio:trimmedWord textLanguage:language];
    };
    if ([self usesTabbedDesign]) {
        CGFloat width = MIN(360 * self.config.fontSizeRatio, self.view.bounds.size.width - 24);
        EZInlineLookupPopover *popover = [[EZInlineLookupPopover alloc] initWithFrame:NSMakeRect(0, 0, width, 270)];
        self.inlineLookupPopover = popover;
        popover.closeCard = ^{ mm_strongify(self); [self dismissInlineLookup]; };
        popover.playPhonetic = ^(EZWordPhonetic *phonetic) {
            mm_strongify(self);
            if (self.inlineLookupService == service) {
                [self.inlineLookupContent stopInlineLookupAudio];
                [service.audioPlayer playWordPhonetic:phonetic designatedService:service];
            }
        };
        popover.retryLookup = ^{ mm_strongify(self); [self retryInlineLookup]; };
        service.result.isShowing = YES;
        service.result.isLoading = YES;
        [self updateInlineLookupPopover];
        [popover presentInView:self.view anchor:anchor range:range];
        startLookup();
    } else {
        [self reloadTableViewData:startLookup];
    }
}

/// Uses the existing detailed renderer only inside the card's own scroll view.
- (void)updateInlineLookupPopover {
    EZQueryService *service = self.inlineLookupService;
    EZInlineLookupPopover *popover = self.inlineLookupPopover;
    if (!service || !popover) { return; }
    EZQueryResult *result = service.result;
    if (!self.inlineLookupContent) {
        self.inlineLookupContent = [[EZWordResultView alloc] initWithFrame:NSMakeRect(0, 0, popover.contentWidth, 0)];
        self.inlineLookupContent.popupStyle = YES;
        self.inlineLookupContent.inlineCard = YES;
        mm_weakify(self);
        self.inlineLookupContent.queryTextBlock = ^(NSString *word) { mm_strongify(self); [self startQueryText:word]; };
        self.inlineLookupContent.retryResultBlock = ^{ mm_strongify(self); [self retryInlineLookup]; };
        self.inlineLookupContent.updateViewHeightBlock = ^(CGFloat height) {
            mm_strongify(self);
            [self.inlineLookupPopover updateFullHeight:height];
        };
    }
    self.inlineLookupContent.service = service;
    [self.inlineLookupContent refreshWithResult:result];
    [popover updateWithResult:result word:self.inlineLookupWord sourceName:service.name
                 fullContent:result.hasShowingResult ? self.inlineLookupContent : nil
                  fullHeight:self.inlineLookupContent.viewHeight fontRatio:self.config.fontSizeRatio];
}

/// Retrying must retain the word model rather than reset to the parent's sentence.
- (void)retryInlineLookup {
    EZQueryService *service = self.inlineLookupService;
    if (!service) { return; }
    [service.queryModel stopServiceRequest:service.serviceTypeWithUniqueIdentifier];
    [service.audioPlayer stop];
    [service resetServiceResult];
    service.result.isShowing = YES;
    service.result.isLoading = YES;
    [self updateInlineLookupPopover];
    [self queryWithModel:service.queryModel service:service];
}

/// Removes the inline lookup card if one is showing.
- (void)removeInlineLookupServiceReloadData:(BOOL)reloadData {
    EZQueryService *service = self.inlineLookupService;
    if (!service) {
        return;
    }

    BOOL wasFloating = self.inlineLookupPopover != nil;
    [self.inlineLookupContent stopInlineLookupAudio];
    [self.inlineLookupPopover dismiss];
    self.inlineLookupPopover = nil;
    self.inlineLookupContent = nil;
    [service.queryModel stopServiceRequest:service.serviceTypeWithUniqueIdentifier];
    [service.audioPlayer stop];
    for (EZQueryService *parent in self.services) {
        [[self resultCellOfResult:parent.result].wordResultView stopInlineLookupAudio];
    }

    NSMutableArray *services = [self.services mutableCopy];
    NSMutableArray *serviceTypeIds = [self.serviceTypeIds mutableCopy];
    NSUInteger index = [services indexOfObject:service];
    if (index != NSNotFound) {
        [services removeObjectAtIndex:index];
        [serviceTypeIds removeObjectAtIndex:index];
        self.services = services;
        self.serviceTypeIds = serviceTypeIds;
    }

    self.inlineLookupService = nil;
    self.inlineLookupWord = nil;

    if (reloadData && !wasFloating) {
        [self reloadTableViewData:nil];
    }
}

- (NSInteger)resultCellOffset {
    NSInteger offset = 0;

    if (self.isInputFieldCellVisible && self.windowType != EZWindowTypeMain) {
        offset += 1;
    }
    if (self.isSelectLanguageCellVisible && ![self embedsPopupLanguageHeader]) {
        offset += 1;
    }
    if (self.isTipsViewVisible) {
        offset += 1;
    }

    if ([self usesTabbedDesign]) {
        offset += 1;
    }
    return offset;
}

- (EZQueryService *)serviceAtRow:(NSInteger)row {
    NSInteger index = row - [self resultCellOffset];
    NSArray<EZQueryService *> *displayed = [self displayedServices];
    if (index < 0 || index >= displayed.count) {
        MMLogError(@"error row: %ld, windowType: %ld", row, self.windowType);
        return nil;
    }

    EZQueryService *service = displayed[index];
    return service;
}

- (nullable EZQueryService *)serviceWithType:(NSString *)serviceTypeId {
    if (!serviceTypeId) {
        return nil;
    }
    NSInteger index = [self.serviceTypeIds indexOfObject:serviceTypeId];
    if (index != NSNotFound) {
        return self.services[index];
    }
    return nil;
}

// Get tableView bounds in real time.
- (CGRect)tableViewContentBounds {
    CGRect rect = CGRectMake(0, 0, self.scrollView.width - 2 * EZHorizontalCellSpacing_10, self.scrollView.height);
    return rect;
}


#pragma mark - Main window presentation

- (void)updateMainSourceView {
    if (self.windowType != EZWindowTypeMain) { return; }
    self.mainSurface.sourceVisible = self.isInputFieldCellVisible;
    self.mainSurface.sideBySide = self.mainSideBySide;
    self.queryView = [self createQueryView];
    self.queryView.associatedWindowType = self.windowType;
    if (self.queryView.superview != self.mainSurface.sourceContainer) {
        [self.mainSurface.sourceContainer addSubview:self.queryView];
        [self.queryView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.equalTo(self.mainSurface.sourceContainer);
        }];
    }
    [self.queryView initializeAimatedButtonAlphaValue:self.queryModel];
    self.queryView.queryModel = self.queryModel;
    self.mainSurface.sourceHeight = [self.queryView heightOfQueryView];
    [self.view layoutSubtreeIfNeeded];
}

/// Called at submission/transfer, so typing never switches the column layout.
- (void)updateMainModeWithText:(NSString *)text language:(EZLanguage)language {
    if (self.windowType != EZWindowTypeMain) { return; }
    BOOL sideBySide = text.length && !([text queryTypeWithLanguage:language maxWordCount:1] & EZQueryTextTypeDictionary);
    BOOL enteringColumns = sideBySide && !self.mainSideBySide;
    self.mainSideBySide = sideBySide;
    NSWindow *window = self.baseQueryWindow ?: self.view.window;
    // Expand only an existing compact frame; keep a user's larger remembered size.
    if (enteringColumns && window && window.frame.size.width < 720) {
        NSRect frame = window.frame;
        frame.size.width = MIN(900, (window.screen ?: NSScreen.mainScreen).visibleFrame.size.width);
        self.isUpdatingWindowFrameInternally = YES;
        [window setFrame:frame display:YES];
        self.isUpdatingWindowFrameInternally = NO;
    }
    [self updateMainSourceView];
    [self updateMainWindowGeometry];
    [self setNeedUpdateIframeHeightForAllResults];
}

- (void)updateMainWindowGeometry {
    NSWindow *window = self.baseQueryWindow ?: self.view.window;
    if (!window) { return; }
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat maximumHeight = visible.size.height * (self.config.maxWindowHeightPercentage / 100.0);
    CGFloat minimumHeight = MIN(260, maximumHeight);
    CGFloat minimumWidth = MIN(self.mainSideBySide ? 720 : 600, visible.size.width);
    BOOL wasUpdatingFrame = self.isUpdatingWindowFrameInternally;
    self.isUpdatingWindowFrameInternally = YES;
    window.minSize = NSMakeSize(minimumWidth, minimumHeight);
    window.maxSize = NSMakeSize(visible.size.width, maximumHeight);
    NSRect frame = window.frame;
    CGFloat height = MAX(minimumHeight, MIN(frame.size.height, maximumHeight));
    frame.origin.y += frame.size.height - height;
    frame.size.height = height;
    frame.size.width = MAX(minimumWidth, MIN(frame.size.width, visible.size.width));
    frame = [EZCoordinateUtils getSafeAreaFrame:frame inScreenVisibleFrame:visible];
    if (!ez_frame_equal_with_tolerance(window.frame, frame, EZLayoutGeometryTolerance_0_5)) {
        [window setFrame:frame display:YES];
    }
    self.isUpdatingWindowFrameInternally = wasUpdatingFrame;
    self.mainSurface.sourceHeight = [self.queryView heightOfQueryView];
    [self.view layoutSubtreeIfNeeded];
}

/// Transfer data only. Each window owns its services, model, audio and WebViews.
- (void)adoptQueryFromController:(EZBaseQueryViewController *)source {
    if (source == self || self.windowType != EZWindowTypeMain) { return; }
    EZQueryModel *model = [source.queryModel copy];
    NSMutableDictionary<NSString *, EZQueryResult *> *snapshots = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *incomplete = [NSMutableSet set];
    for (EZQueryService *service in source.services) {
        if (service == source.inlineLookupService) { continue; }
        NSString *serviceID = service.serviceTypeWithUniqueIdentifier;
        snapshots[serviceID] = [service.result windowSnapshotWithModel:model];
        if ([source.runningPopupServices containsObject:serviceID] ||
            [source.stoppedPopupServices containsObject:serviceID] ||
            [source.incompleteWindowSnapshots containsObject:serviceID] ||
            (service.isStream && !service.result.isStreamFinished)) {
            [incomplete addObject:serviceID];
        }
    }
    NSString *selectedID = source.selectedPopupServiceID;
    NSString *firstID = source.firstService.serviceTypeWithUniqueIdentifier;
    [self cancelAutoQuery];
    [self cancelDelayDetectQueryText];
    [self.queryModel stopAllService];
    [self stopPlayingQueryText];
    [self removeInlineLookupServiceReloadData:NO];
    self.queryModel = model;
    self.detectManager = [EZDetectManager managerWithModel:model];
    [self setupServices:[self latestServices]];
    // Include transferred services for this display without changing stored enablement.
    NSMutableArray *services = self.services.mutableCopy;
    NSMutableArray *serviceIDs = self.serviceTypeIds.mutableCopy;
    for (EZQueryService *sourceService in source.services) {
        NSString *serviceID = sourceService.serviceTypeWithUniqueIdentifier;
        if (sourceService != source.inlineLookupService && ![serviceIDs containsObject:serviceID]) {
            EZQueryService *service = [EZLocalStorage.shared service:serviceID windowType:self.windowType];
            if (service) {
                [self resetService:service];
                [services addObject:service];
                [serviceIDs addObject:serviceID];
            }
        }
    }
    self.services = services.copy;
    self.serviceTypeIds = serviceIDs.copy;
    for (EZQueryService *service in self.services) {
        EZQueryResult *snapshot = snapshots[service.serviceTypeWithUniqueIdentifier];
        if (snapshot) { service.result = snapshot; }
        service.autoCopyTranslatedTextBlock = nil;
    }
    self.incompleteWindowSnapshots = incomplete;
    self.stoppedPopupServices = source.stoppedPopupServices.mutableCopy;
    self.selectedPopupServiceID = selectedID && [serviceIDs containsObject:selectedID] ? selectedID : serviceIDs.firstObject;
    self.firstService = [self serviceWithType:firstID];
    // Avoid invoking the input setter: a transferred model has already been populated.
    _inputText = [source.inputText copy];
    self.isTipsViewVisible = NO;
    EZQueryResult *primary = snapshots[selectedID ?: @""];
    NSString *submittedText = primary.queryText.length ? primary.queryText : model.queryText;
    EZLanguage submittedLanguage = primary.queryText.length ? primary.from : model.queryFromLanguage;
    [self updateMainModeWithText:submittedText language:submittedLanguage];
    [self updateWindowConfiguration:nil];
    [self.scrollView.contentView scrollToPoint:NSZeroPoint];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

#pragma mark - Popup presentation

- (BOOL)embedsPopupLanguageHeader {
    return [self usesTabbedDesign] && self.isInputFieldCellVisible && self.isSelectLanguageCellVisible;
}

- (BOOL)usesTabbedDesign {
    return self.windowType == EZWindowTypeMini || self.windowType == EZWindowTypeFixed || self.windowType == EZWindowTypeMain;
}

/// Requests use the complete service array; table rows use the selected result.
- (NSArray<EZQueryService *> *)displayedServices {
    if (![self usesTabbedDesign]) {
        return self.services;
    }
    NSMutableArray *displayed = [NSMutableArray array];
    EZQueryService *selected = [self serviceWithType:self.selectedPopupServiceID];
    if (selected) {
        [displayed addObject:selected];
    }
    // The inline service remains in the request array, but has no table row.
    return displayed;
}

- (BOOL)isPopupServiceBarAtRow:(NSInteger)row {
    return [self usesTabbedDesign] && row == [self resultCellOffset] - 1;
}

- (void)updatePopupServiceBar {
    if (![self usesTabbedDesign]) {
        return;
    }
    if (!self.popupServiceBar) {
        self.popupServiceBar = [[EZPopupServiceBar alloc] initWithFrame:[self tableViewContentBounds]];
        mm_weakify(self);
        self.popupServiceBar.selectService = ^(NSString *serviceID) {
            mm_strongify(self);
            [self selectPopupService:serviceID];
        };
        self.popupServiceBar.copyResult = ^{
            mm_strongify(self);
            EZQueryResult *result = [self serviceWithType:self.selectedPopupServiceID].result;
            if (result.copiedText.length) {
                [result.copiedText ns_copyAndShowToast:YES];
            }
        };
        self.popupServiceBar.showActions = ^{
            mm_strongify(self);
            EZQueryService *selected = [self serviceWithType:self.selectedPopupServiceID];
            NSUInteger index = [self rowIndexOfResult:selected.result];
            if (index == NSNotFound) {
                return;
            }
            NSInteger row = index + [self resultCellOffset];
            EZResultView *cell = (EZResultView *)[self.tableView viewAtColumn:0 row:row makeIfNecessary:YES];
            [cell.wordResultView showActionsMenuFromView:self.popupServiceBar];
        };
        self.popupServiceBar.stopQuery = ^{
            mm_strongify(self);
            for (EZQueryService *service in self.services) {
                if (service == self.inlineLookupService) {
                    continue;
                }
                if ([self.runningPopupServices containsObject:service.serviceTypeWithUniqueIdentifier]) {
                    [self.stoppedPopupServices addObject:service.serviceTypeWithUniqueIdentifier];
                }
            }
            [self.queryModel stopAllService];
            [self.runningPopupServices removeAllObjects];
            [self reloadTableViewData:nil];
        };
    }
    EZQueryResult *result = [self serviceWithType:self.selectedPopupServiceID].result;
    BOOL running = NO;
    NSMutableArray *tabServices = [NSMutableArray array];
    for (EZQueryService *service in self.services) {
        if (service == self.inlineLookupService) {
            continue;
        }
        [tabServices addObject:service];
        running |= [self.runningPopupServices containsObject:service.serviceTypeWithUniqueIdentifier];
    }
    BOOL stale = result.queryText.length && (![result.queryText isEqualToString:self.queryText]
        || ![result.from isEqualToString:self.queryModel.queryFromLanguage]
        || ![result.to isEqualToString:self.queryModel.queryTargetLanguage]);
    BOOL stopped = self.selectedPopupServiceID && [self.stoppedPopupServices containsObject:self.selectedPopupServiceID];
    BOOL incomplete = stopped || [self.incompleteWindowSnapshots containsObject:self.selectedPopupServiceID ?: @""];
    incomplete |= result.error != nil && result.hasTranslatedResult;
    BOOL selectedRunning = self.selectedPopupServiceID && [self.runningPopupServices containsObject:self.selectedPopupServiceID];
    CGFloat previousHeight = self.popupServiceBar.preferredHeight;
    [self.popupServiceBar updateWithServices:tabServices selectedID:self.selectedPopupServiceID
                                    canCopy:result.copiedText.length > 0 isRunning:running
                            selectedRunning:selectedRunning incomplete:incomplete stopped:stopped stale:stale];
    NSInteger barRow = [self resultCellOffset] - 1;
    if (previousHeight != self.popupServiceBar.preferredHeight && barRow >= 0 && barRow < self.tableView.numberOfRows) {
        [self.tableView noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:barRow]];
    }
}

- (void)selectPopupService:(NSString *)serviceID {
    EZQueryService *service = [self serviceWithType:serviceID];
    if (!service) {
        return;
    }
    if ([self.selectedPopupServiceID isEqualToString:serviceID]) {
        if (!service.result.hasShowingResult && ![self.runningPopupServices containsObject:serviceID]) {
            service.result.isShowing = YES;
            service.result.manualShow = YES;
            [self handleArrowToggleForResult:service.result service:service isShowing:YES];
        }
        return;
    }
    if (self.selectedPopupServiceID) {
        self.popupScrollPositions[self.selectedPopupServiceID] = [NSValue valueWithPoint:self.scrollView.contentView.bounds.origin];
    }
    [[self resultCellOfResult:[self serviceWithType:self.selectedPopupServiceID].result].wordResultView stopInlineLookupAudio];
    [self stopAllResultAudio];
    [self removeInlineLookupServiceReloadData:NO];
    self.selectedPopupServiceID = serviceID;
    service.result.isShowing = YES;
    service.result.manualShow = YES;
    [self reloadTableViewData:^{
        if (![self.selectedPopupServiceID isEqualToString:serviceID]) {
            return;
        }
        NSValue *position = self.popupScrollPositions[serviceID];
        [self.scrollView.contentView scrollToPoint:position ? position.pointValue : NSZeroPoint];
        [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
        if (![self.runningPopupServices containsObject:serviceID]) {
            [self handleArrowToggleForResult:service.result service:service isShowing:YES];
        }
    }];
}

#pragma mark - Update Window Height

- (void)updateWindowHeight {
    [self updateWindowHeightWithLock:YES];
}

- (void)updateWindowHeightWithLock:(BOOL)lockFlag {
    if (self.windowType == EZWindowTypeMain) {
        [self updateMainWindowGeometry];
        self.tableView.height = [self getScrollViewContentHeight];
        return;
    }
    if (lockFlag) {
        self.lockResizeWindow = YES;
    }

        MMLogInfo(@"updateWindowViewHeightWithLock");

    CGFloat tableViewHeight = [self getScrollViewContentHeight];
    CGFloat height = [self getRestrainedScrollViewHeight:tableViewHeight];
    //    MMLogInfo(@"getRestrainedScrollViewHeight: %@", @(height));

    CGSize maxWindowSize = [EZLayoutManager.shared maximumWindowSize:self.windowType];

    CGFloat titleBarHeight = EZTitlebarHeight_28; // system title bar height is 28

    CGFloat scrollViewHeight = height + self.scrollView.contentInsets.top + self.scrollView.contentInsets.bottom;
    scrollViewHeight = MIN(scrollViewHeight, maxWindowSize.height - titleBarHeight);
    //    MMLogInfo(@"scrollViewHeight: %@", @(scrollViewHeight));

    // Diable change window height manually.
    [self.scrollView mas_updateConstraints:^(MASConstraintMaker *make) {
        make.height.equalTo(@(scrollViewHeight)).priority(MASLayoutPriorityDefaultHigh);
    }];

    CGFloat showingWindowHeight = scrollViewHeight + titleBarHeight;
    showingWindowHeight = MIN(showingWindowHeight, maxWindowSize.height);

    // Since changing height will cause position change, adjust y to keep top-left coordinate stable.
    NSWindow *window = self.baseQueryWindow ?: self.view.window;
    if (!window) {
        self.lockResizeWindow = NO;
        return;
    }

    CGFloat deltaHeight = window.height - showingWindowHeight;
    CGFloat y = window.y + deltaHeight;

    CGRect newFrame = CGRectMake(window.x, y, window.width, showingWindowHeight);

    // Use the window's current screen. The cached one only refreshes on clicks,
    // so on multi-monitor setups it can yank the window back to the old display.
    // window.screen picks the display with the largest overlap, which handles
    // cross-screen drags better than our own first-intersect lookup.
    NSScreen *currentScreen = window.screen ?: [EZCoordinateUtils screenForRect:newFrame] ?: NSScreen.mainScreen;
    CGRect screenVisibleFrame = currentScreen.visibleFrame;
    CGRect safeFrame = [EZCoordinateUtils getSafeAreaFrame:newFrame inScreenVisibleFrame:screenVisibleFrame];

    if (ez_frame_equal_with_tolerance(window.frame,
                                      safeFrame,
                                      EZLayoutGeometryTolerance_0_5)) {
        self.tableView.height = tableViewHeight;
        self.lockResizeWindow = NO;
        MMLogInfo(@"Equal frame, no need to update window frame");
        return;
    }

    // ???: why set window frame will change tableView height?
    // ???: why this window animation will block cell rendering?
    //    [self.window setFrame:safeFrame display:NO animate:animateFlag];
    self.isUpdatingWindowFrameInternally = YES;
    [window setFrame:safeFrame display:YES];
    [self restoreFirstResponderIfWindowIsKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isUpdatingWindowFrameInternally = NO;
    });

    // Restore tableView height.
    self.tableView.height = tableViewHeight;

    // Animation cost time.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(EZUpdateTableViewRowHeightAnimationDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.lockResizeWindow = NO;
        [self restoreFirstResponderIfWindowIsKey];
    });

    //    MMLogInfo(@"window frame: %@", @(window.frame));
}

- (void)restoreFirstResponderIfWindowIsKey {
    if (self.baseQueryWindow.isKeyWindow && self.queryView.window == self.baseQueryWindow) {
        NSResponder *curr = self.baseQueryWindow.firstResponder;
        BOOL isFocusEmpty = (curr == nil || curr == self.baseQueryWindow || curr == self.baseQueryWindow.contentView);
        if (isFocusEmpty) {
            [self.baseQueryWindow makeFirstResponder:self.queryView.textView];
        }
    }
}

- (CGFloat)getRestrainedScrollViewHeight:(CGFloat)scrollViewContentHeight {
    CGFloat height = scrollViewContentHeight;

    CGSize minimumWindowSize = [EZLayoutManager.shared minimumWindowSize:self.windowType];
    CGSize maximumWindowSize = [EZLayoutManager.shared maximumWindowSize:self.windowType];

    height = MAX(height, minimumWindowSize.height);
    height = MIN(height, maximumWindowSize.height);

    return height;
}

/// Manually calculate tableView row height.
- (CGFloat)getScrollViewContentHeight {
    CGFloat scrollViewContentHeight = 0;

    NSInteger rowCount = [self numberOfRowsInTableView:self.tableView];
    for (int i = 0; i < rowCount; i++) {
        CGFloat rowHeight = [self tableView:self.tableView heightOfRow:i];
        //        MMLogInfo(@"row: %d, Height: %.1f", i, rowHeight);
        scrollViewContentHeight += (rowHeight + EZVerticalCellSpacing_7);
    }
    //    MMLogInfo(@"scrollViewContentHeight: %.1f", scrollViewContentHeight);


    return scrollViewContentHeight;
}

/// Auto calculate documentView height.
- (CGFloat)getContentHeight {
    // Modify scrollView height to 0, to get actual tableView content height, avoid blank view.
    self.scrollView.height = 0;

    CGFloat documentViewHeight = self.scrollView.documentView.height; // actually is tableView height
    //    MMLogInfo(@"documentView height: %@", @(documentViewHeight));

    return documentViewHeight;
}

- (CGFloat)miniQueryViewHeight {
    if ([self usesTabbedDesign]) {
        return self.queryView ? [self.queryView heightOfQueryView] : 98;
    }
    CGFloat miniInputViewHeight = [[EZLayoutManager shared] inputViewMinHeight:self.windowType];
    CGFloat queryViewHeight = miniInputViewHeight + EZQueryViewExceptInputViewHeight;
    return queryViewHeight;
}

#pragma mark - Auto play English word

- (void)autoPlayEnglishWordAudio {
    if (!self.config.autoPlayAudio) {
        return;
    }

    BOOL isEnglishWord = [self.queryText isEnglishWordWithLanguage:self.queryModel.queryFromLanguage];
    if (!isEnglishWord) {
        return;
    }

    MMLogInfo(@"Auto play English word audio: %@", self.queryText);
    [self togglePlayQueryText:YES];
}

#pragma mark -

/// Auto copy translated text.
- (void)autoCopyTranslatedTextOfService:(EZQueryService *)service {
    if (![self.config autoCopyFirstTranslatedText]) {
        service.autoCopyTranslatedTextBlock = nil;
        return;
    }

    [service setAutoCopyTranslatedTextBlock:^(EZQueryResult *result, NSError *error) {
        if (!result.htmlString.length) {
            [result.copiedText copyToPasteboard];
            return;
        }

        mm_weakify(result);
        [result setDidFinishLoadingHTMLBlock:^{
            mm_strongify(result);
            [result.copiedText copyToPasteboard];
        }];
    }];
}

- (BOOL)isCustomTipsType {
    return self.tipsCellType == EZTipsCellTypeErrorTips ||
        self.tipsCellType == EZTipsCellTypeInfoTips ||
        self.tipsCellType == EZTipsCellTypeWarnTips;
}

- (BOOL)isInputFieldCellAtRow:(NSInteger)row {
    return self.windowType != EZWindowTypeMain && row == self.inputFieldCellIndex && self.isInputFieldCellVisible;
}

- (BOOL)isSelectLanguageCellAtRow:(NSInteger)row {
    return row == self.selectLanguageCellIndex && self.isSelectLanguageCellVisible && ![self embedsPopupLanguageHeader];
}

- (BOOL)isTipsViewAtRow:(NSInteger)row {
    return row == self.tipsCellIndex && self.isTipsViewVisible;
}

@end
