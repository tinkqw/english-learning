//
//  EZCommonResultView.h
//  Easydict
//
//  Created by tisfeng on 2022/11/9.
//  Copyright © 2022 izual. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class EZQueryResult;
@class EZQueryService;

NS_ASSUME_NONNULL_BEGIN

@interface EZWordResultView : NSView <WKNavigationDelegate>

@property (nonatomic, assign, readonly) CGFloat viewHeight;
@property (nonatomic, strong, readonly) EZQueryResult *result;
@property (nonatomic, strong) EZQueryService *service;
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic, strong, readonly) NSButton *replaceTextButton;

@property (nonatomic, assign) BOOL popupStyle;
@property (nonatomic, assign) BOOL inlineCard;
@property (nonatomic, copy, nullable) void (^retryResultBlock)(void);
@property (nonatomic, strong, nullable) NSMenu *modelSelectionMenu;

/// Reuses existing actions through the popup's more menu.
- (void)showActionsMenuFromView:(NSView *)anchor;
/// Stops both service playback and the view's separate pronunciation players.
- (void)stopInlineLookupAudio;


@property (nonatomic, copy) void (^queryTextBlock)(NSString *word);

/// Called when the user clicks an inline-lookup link inside the result text.
/// Unlike `queryTextBlock`, the host is expected to keep the current query and
/// present a dictionary card at the clicked range instead of replacing the query.
@property (nonatomic, copy) void (^inlineLookupBlock)(NSString *word, NSTextView *anchor, NSRange range);

@property (nonatomic, copy) void (^updateViewHeightBlock)(CGFloat viewHeight);

@property (nonatomic, copy) void (^didFinishLoadingHTMLBlock)(void);

- (void)refreshWithResult:(EZQueryResult *)result;

@end

NS_ASSUME_NONNULL_END
