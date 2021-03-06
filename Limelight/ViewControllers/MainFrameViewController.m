//  MainFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "MainFrameViewController.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Connection.h"
#import "StreamManager.h"
#import "Utils.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "App.h"
#import "SettingsViewController.h"
#import "DataManager.h"
#import "Settings.h"
#import "WakeOnLanManager.h"
#import "AppListResponse.h"
#import "ServerInfoResponse.h"
#import "StreamFrameViewController.h"
#import "LoadingFrameViewController.h"

@implementation MainFrameViewController {
    NSOperationQueue* _opQueue;
    Host* _selectedHost;
    NSString* _uniqueId;
    NSData* _cert;
    DiscoveryManager* _discMan;
    AppAssetManager* _appManager;
    StreamConfiguration* _streamConfig;
    UIAlertController* _pairAlert;
    UIScrollView* hostScrollView;
    int currentPosition;
    NSArray* _sortedAppList;
}
static NSMutableSet* hostList;

- (void)showPIN:(NSString *)PIN {
    dispatch_async(dispatch_get_main_queue(), ^{
        _pairAlert = [UIAlertController alertControllerWithTitle:@"Pairing"
                                                         message:[NSString stringWithFormat:@"Enter the following PIN on the host machine: %@", PIN]
                                                  preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:_pairAlert animated:YES completion:nil];
    });
}

- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_pairAlert dismissViewControllerAnimated:YES completion:nil];
        _pairAlert = [UIAlertController alertControllerWithTitle:@"Pairing Failed"
                                                         message:message
                                                  preferredStyle:UIAlertControllerStyleAlert];
        [_pairAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
        [self presentViewController:_pairAlert animated:YES completion:nil];
        
        [_discMan startDiscovery];
        [self hideLoadingFrame];
    });
}

- (void)pairSuccessful {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_pairAlert dismissViewControllerAnimated:YES completion:nil];
        [_discMan startDiscovery];
        [self alreadyPaired];
    });
}

- (void)alreadyPaired {
    BOOL usingCachedAppList = false;
    
    // Capture the host here because it can change once we
    // leave the main thread
    Host* host = _selectedHost;
    
    if ([host.appList count] > 0) {
        usingCachedAppList = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host != _selectedHost) {
                return;
            }
            
            _computerNameButton.title = host.name;
            [self.navigationController.navigationBar setNeedsLayout];
            
            [self updateAppsForHost:host];
            [self hideLoadingFrame];
        });
    }
    Log(LOG_I, @"Using cached app list: %d", usingCachedAppList);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:_uniqueId deviceName:deviceName cert:_cert];
        
        AppListResponse* appListResp = [[AppListResponse alloc] init];
        
        // Exempt this host from discovery while handling the applist query
        [_discMan removeHostFromDiscovery:host];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appListResp withUrlRequest:[hMan newAppListRequest]]];
        [_discMan addHostToDiscovery:host];

        if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingFrame];
                
                if (host != _selectedHost) {
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Fetching App List Failed"
                                                                                      message:@"The connection to the PC was interrupted."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                [self presentViewController:applistAlert animated:YES completion:nil];
                host.online = NO;
                [self showHostSelectionView];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self mergeAppLists:[appListResp getAppList] forHost:host];

                if (host != _selectedHost) {
                    return;
                }
                
                _computerNameButton.title = host.name;
                [self.navigationController.navigationBar setNeedsLayout];
                
                [self updateAppsForHost:host];
                [_appManager stopRetrieving];
                [_appManager retrieveAssetsFromHost:host];
                [self hideLoadingFrame];
            });
        }
    });
}

- (void) mergeAppLists:(NSArray*) newList forHost:(Host*)host {
    DataManager* database = [[DataManager alloc] init];
    for (App* app in newList) {
        BOOL appAlreadyInList = NO; 
        for (App* savedApp in host.appList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.isRunning = app.isRunning;
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [host addAppListObject:app];
        } else {
            [database removeApp:app];
        }
    }
    
    for (App* app in host.appList) {
        BOOL appWasRemoved = YES;
        for (App* mergedApp in newList) {
            if ([mergedApp.id isEqualToString:app.id]) {
                appWasRemoved = NO;
                break;
            }
        }
        if (appWasRemoved) {
            [host removeAppListObject:app];
            [database removeApp:app];
        }
    }
    [database saveData];
}

- (void)showHostSelectionView {
    [_appManager stopRetrieving];
    [[[DataManager alloc] init] saveData];
    _selectedHost = nil;
    _computerNameButton.title = @"No Host Selected";
    [self.collectionView reloadData];
    [self.view addSubview:hostScrollView];
}

- (void) receivedAssetForApp:(App*)app {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)displayDnsFailedDialog {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Network Error"
                                                                   message:@"Failed to resolve host."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) hostClicked:(Host *)host view:(UIView *)view {
    // Treat clicks on offline hosts to be long clicks
    // This shows the context menu with wake, delete, etc. rather
    // than just hanging for a while and failing as we would in this
    // code path.
    if (!host.online && view != nil) {
        [self hostLongClicked:host view:view];
        return;
    }
    
    Log(LOG_D, @"Clicked host: %@", host.name);
    _selectedHost = host;
    [self disableNavigation];
    
    // If we are online, paired, and have a cached app list, skip straight
    // to the app grid without a loading frame. This is the fast path that users
    // should hit most.
    if (host.online && host.pairState == PairStatePaired && host.appList.count > 0) {
        [self alreadyPaired];
        return;
    }
    
    [self showLoadingFrame];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:_uniqueId deviceName:deviceName cert:_cert];
        ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
        
        // Exempt this host from discovery while handling the serverinfo request
        [_discMan removeHostFromDiscovery:host];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest]
                                           fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        [_discMan addHostToDiscovery:host];
        
        if (serverInfoResp == nil || ![serverInfoResp isStatusOk]) {
            Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingFrame];
                
                if (host != _selectedHost) {
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Fetching Server Info Failed"
                                                                                      message:@"The connection to the PC was interrupted."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                [self presentViewController:applistAlert animated:YES completion:nil];
                host.online = NO;
                [self showHostSelectionView];
            });
        } else {
            Log(LOG_D, @"server info pair status: %@", [serverInfoResp getStringTag:@"PairStatus"]);
            if ([[serverInfoResp getStringTag:@"PairStatus"] isEqualToString:@"1"]) {
                Log(LOG_I, @"Already Paired");
                [self alreadyPaired];
            } else {
                Log(LOG_I, @"Trying to pair");
                // Polling the server while pairing causes the server to screw up
                [_discMan stopDiscoveryBlocking];
                PairManager* pMan = [[PairManager alloc] initWithManager:hMan andCert:_cert callback:self];
                [_opQueue addOperation:pMan];
            }
        }
    });
}

- (void)hostLongClicked:(Host *)host view:(UIView *)view {
    Log(LOG_D, @"Long clicked host: %@", host.name);
    UIAlertController* longClickAlert = [UIAlertController alertControllerWithTitle:host.name message:@"" preferredStyle:UIAlertControllerStyleActionSheet];
    if (!host.online) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Wake" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            UIAlertController* wolAlert = [UIAlertController alertControllerWithTitle:@"Wake On Lan" message:@"" preferredStyle:UIAlertControllerStyleAlert];
            [wolAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            if (host.pairState != PairStatePaired) {
                wolAlert.message = @"Cannot wake host because you are not paired";
            } else if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
                wolAlert.message = @"Host MAC unknown, unable to send WOL Packet";
            } else {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [WakeOnLanManager wakeHost:host];
                });
                wolAlert.message = @"Sent WOL Packet";
            }
            [self presentViewController:wolAlert animated:YES completion:nil];
        }]];
    }
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Remove Host" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [_discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        @synchronized(hostList) {
            [hostList removeObject:host];
        }
        [self updateAllHosts:[hostList allObjects]];
        
    }]];
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // these two lines are required for iPad support of UIAlertSheet
    longClickAlert.popoverPresentationController.sourceView = view;
    
    longClickAlert.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0); // center of the view
    [self presentViewController:longClickAlert animated:YES completion:^{
        [self updateHosts];
    }];
}

- (void) addHostClicked {
    Log(LOG_D, @"Clicked add host");
    [self showLoadingFrame];
    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"Host Address" message:@"Please enter a hostname or IP address" preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        NSString* hostAddress = ((UITextField*)[[alertController textFields] objectAtIndex:0]).text;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [_discMan discoverHost:hostAddress withCallback:^(Host* host, NSString* error){
                if (host != nil) {
                    DataManager* dataMan = [[DataManager alloc] init];
                    [dataMan saveData];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @synchronized(hostList) {
                            [hostList addObject:host];
                        }
                        [self updateHosts];
                    });
                } else {
                    UIAlertController* hostNotFoundAlert = [UIAlertController alertControllerWithTitle:@"Add Host" message:error preferredStyle:UIAlertControllerStyleAlert];
                    [hostNotFoundAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self presentViewController:hostNotFoundAlert animated:YES completion:nil];
                    });
                }
            }];});
    }]];
    [alertController addTextFieldWithConfigurationHandler:nil];
    [self hideLoadingFrame];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void) appClicked:(App *)app {
    Log(LOG_D, @"Clicked app: %@", app.name);
    _streamConfig = [[StreamConfiguration alloc] init];
    _streamConfig.host = app.host.activeAddress;
    _streamConfig.appID = app.id;
    
    DataManager* dataMan = [[DataManager alloc] init];
    Settings* streamSettings = [dataMan retrieveSettings];
    
    _streamConfig.frameRate = [streamSettings.framerate intValue];
    _streamConfig.bitRate = [streamSettings.bitrate intValue];
    _streamConfig.height = [streamSettings.height intValue];
    _streamConfig.width = [streamSettings.width intValue];
    
    [_appManager stopRetrieving];
    
    if (currentPosition != FrontViewPositionLeft) {
        [[self revealViewController] revealToggle:self];
    }
    
    App* currentApp = [self findRunningApp:app.host];
    if (currentApp != nil) {
        UIAlertController* alertController = [UIAlertController
                                              alertControllerWithTitle: app.name
                                              message: [app.id isEqualToString:currentApp.id] ? @"" : [NSString stringWithFormat:@"%@ is currently running", currentApp.name]preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction
                                    actionWithTitle:[app.id isEqualToString:currentApp.id] ? @"Resume App" : @"Resume Running App" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
                                        Log(LOG_I, @"Resuming application: %@", currentApp.name);
                                        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
                                    }]];
        [alertController addAction:[UIAlertAction actionWithTitle:
                                    [app.id isEqualToString:currentApp.id] ? @"Quit App" : @"Quit Running App and Start" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action){
                                        Log(LOG_I, @"Quitting application: %@", currentApp.name);
                                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                            HttpManager* hMan = [[HttpManager alloc] initWithHost:app.host.activeAddress uniqueId:_uniqueId deviceName:deviceName cert:_cert];
                                            HttpResponse* quitResponse = [[HttpResponse alloc] init];
                                            HttpRequest* quitRequest = [HttpRequest requestForResponse: quitResponse withUrlRequest:[hMan newQuitAppRequest]];
                                            
                                            // Exempt this host from discovery while handling the quit operation
                                            [_discMan removeHostFromDiscovery:app.host];
                                            [hMan executeRequestSynchronously:quitRequest];
                                            [_discMan addHostToDiscovery:app.host];
                                            
                                            UIAlertController* alert;
                                            
                                            // If it fails, display an error and stop the current operation
                                            if (quitResponse.statusCode != 200) {
                                               alert = [UIAlertController alertControllerWithTitle:@"Quitting App Failed"
                                                                                      message:@"Failed to quit app. If this app was started by "
                                                        "another device, you'll need to quit from that device."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                                            }
                                            // If it succeeds and we're to start streaming, segue to the stream and return
                                            else if (![app.id isEqualToString:currentApp.id]) {
                                                currentApp.isRunning = NO;
                                                
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    [self updateAppsForHost:app.host];
                                                    [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
                                                });
                                                
                                                return;
                                            }
                                            // Otherwise, display a dialog to notify the user that the app was quit
                                            else {
                                                currentApp.isRunning = NO;
                                                
                                                alert = [UIAlertController alertControllerWithTitle:@"Quitting App"
                                                                                            message:@"The app was quit successfully."
                                                                                     preferredStyle:UIAlertControllerStyleAlert];
                                            }
                                            
                                            [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                [self updateAppsForHost:app.host];
                                                [self presentViewController:alert animated:YES completion:nil];
                                            });
                                        });
                                    }]];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    } else {
        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }
}

- (App*) findRunningApp:(Host*)host {
    for (App* app in host.appList) {
        if (app.isRunning) {
            return app;
        }
    }
    return nil;
}

- (void)revealController:(SWRevealViewController *)revealController didMoveToPosition:(FrontViewPosition)position {
    // If we moved back to the center position, we should save the settings
    if (position == FrontViewPositionLeft) {
        [(SettingsViewController*)[revealController rearViewController] saveSettings];
    }
    currentPosition = position;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[StreamFrameViewController class]]) {
        StreamFrameViewController* streamFrame = segue.destinationViewController;
        streamFrame.streamConfig = _streamConfig;
    }
}

- (void) showLoadingFrame {
    LoadingFrameViewController* loadingFrame = [self.storyboard instantiateViewControllerWithIdentifier:@"loadingFrame"];
    [self.navigationController presentViewController:loadingFrame animated:YES completion:nil];
}

- (void) hideLoadingFrame {
    [self dismissViewControllerAnimated:YES completion:nil];
    [self enableNavigation];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Set the side bar button action. When it's tapped, it'll show the sidebar.
    [_limelightLogoButton addTarget:self.revealViewController action:@selector(revealToggle:) forControlEvents:UIControlEventTouchDown];
    
    // Set the host name button action. When it's tapped, it'll show the host selection view.
    [_computerNameButton setTarget:self];
    [_computerNameButton setAction:@selector(showHostSelectionView)];
    
    // Set the gesture
    [self.view addGestureRecognizer:self.revealViewController.panGestureRecognizer];
    
    // Get callbacks associated with the viewController
    [self.revealViewController setDelegate:self];
    
    // Set the current position to the center
    currentPosition = FrontViewPositionLeft;
    
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSl];
    _uniqueId = [CryptoManager getUniqueID];
    _cert = [CryptoManager readCertFromFile];

    _appManager = [[AppAssetManager alloc] initWithCallback:self];
    _opQueue = [[NSOperationQueue alloc] init];
    
    // Only initialize the host picker list once
    if (hostList == nil) {
        hostList = [[NSMutableSet alloc] init];
    }
    
    [self setAutomaticallyAdjustsScrollViewInsets:NO];
    
    hostScrollView = [[UIScrollView alloc] init];
    hostScrollView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.origin.y + self.navigationController.navigationBar.frame.size.height, self.view.frame.size.width, self.view.frame.size.height / 2);
    [hostScrollView setShowsHorizontalScrollIndicator:NO];
    
    [self retrieveSavedHosts];
    _discMan = [[DiscoveryManager alloc] initWithHosts:[hostList allObjects] andCallback:self];
    
    [self updateHosts];
    [self.view addSubview:hostScrollView];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    
    // Hide 1px border line
    UIImage* fakeImage = [[UIImage alloc] init];
    [self.navigationController.navigationBar setShadowImage:fakeImage];
    [self.navigationController.navigationBar setBackgroundImage:fakeImage forBarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
    
    [_discMan startDiscovery];
    
    // This will refresh the applist
    if (_selectedHost != nil) {
        [self hostClicked:_selectedHost view:nil];
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    // when discovery stops, we must create a new instance because you cannot restart an NSOperation when it is finished
    [_discMan stopDiscovery];
    
    // In case the host objects were updated in the background
    [[[DataManager alloc] init] saveData];
}

- (void) retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan retrieveHosts];
    @synchronized(hostList) {
        [hostList addObjectsFromArray:hosts];
        
        // Initialize the non-persistent host state
        for (Host* host in hostList) {
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
        }
    }
}

- (void) updateAllHosts:(NSArray *)hosts {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (Host* host in hosts) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.uuid, host.mac, host.pairState, host.online, host.activeAddress);
        }
        @synchronized(hostList) {
            [hostList removeAllObjects];
            [hostList addObjectsFromArray:hosts];
        }
        [self updateHosts];
    });
}

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
    [[hostScrollView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    UIComputerView* addComp = [[UIComputerView alloc] initForAddWithCallback:self];
    UIComputerView* compView;
    float prevEdge = -1;
    @synchronized (hostList) {
        for (Host* comp in hostList) {
            compView = [[UIComputerView alloc] initWithComputer:comp andCallback:self];
            compView.center = CGPointMake([self getCompViewX:compView addComp:addComp prevEdge:prevEdge], hostScrollView.frame.size.height / 2);
            prevEdge = compView.frame.origin.x + compView.frame.size.width;
            [hostScrollView addSubview:compView];
        }
    }
    prevEdge = [self getCompViewX:addComp addComp:addComp prevEdge:prevEdge];
    addComp.center = CGPointMake(prevEdge, hostScrollView.frame.size.height / 2);
    
    [hostScrollView addSubview:addComp];
    [hostScrollView setContentSize:CGSizeMake(prevEdge + addComp.frame.size.width, hostScrollView.frame.size.height)];
}

- (float) getCompViewX:(UIComputerView*)comp addComp:(UIComputerView*)addComp prevEdge:(float)prevEdge {
    if (prevEdge == -1) {
        return hostScrollView.frame.origin.x + comp.frame.size.width / 2 + addComp.frame.size.width / 2;
    } else {
        return prevEdge + addComp.frame.size.width / 2  + comp.frame.size.width / 2;
    }
}

- (void) updateAppsForHost:(Host*)host {
    if (host != _selectedHost) {
        Log(LOG_W, @"Mismatched host during app update");
        return;
    }
    
    _sortedAppList = [host.appList allObjects];
    _sortedAppList = [_sortedAppList sortedArrayUsingSelector:@selector(compareName:)];
    
    [hostScrollView removeFromSuperview];
    [self.collectionView reloadData];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AppCell" forIndexPath:indexPath];
    
    App* app = _sortedAppList[indexPath.row];
    UIAppView* appView = [[UIAppView alloc] initWithApp:app andCallback:self];
    [appView updateAppImage];
    
    if (appView.bounds.size.width > 10.0) {
        CGFloat scale = cell.bounds.size.width / appView.bounds.size.width;
        [appView setCenter:CGPointMake(appView.bounds.size.width / 2 * scale, appView.bounds.size.height / 2 * scale)];
        appView.transform = CGAffineTransformMakeScale(scale, scale);
    }
    
    [cell.subviews.firstObject removeFromSuperview]; // Remove a view that was previously added
    [cell addSubview:appView];
    
    return cell;
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1; // App collection only
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (_selectedHost != nil) {
        return _selectedHost.appList.count;
    }
    else {
        return 0;
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (void) disableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = NO;
}

- (void) enableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = YES;
}

@end
