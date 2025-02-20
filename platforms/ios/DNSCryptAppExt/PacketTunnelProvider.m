/* Copyright (C) 2019 Sergey Smirnov
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#import "PacketTunnelProvider.h"
#import "DNSCryptThread.h"
#import "Migrator.h"
#import "NetTester.h"

@implementation PacketTunnelProvider

- (DNSCryptThread *)dns {
    return _dns;
}

- (Reachability *)reach {
    return _reach;
}

- (NSUserDefaults *)sharedDefs {
    return [[NSUserDefaults alloc] initWithSuiteName: @"group.org.techcultivation.dnscloak"];
}

- (NSURL *)sharedDir {
    return [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.org.techcultivation.dnscloak"];
}

- (NSDate *)lastForcedResolversCheck {
    return _lastForcedResolversCheck;
}

- (void)preflightCheck {
    [Migrator preflightCheck];
    [Migrator resetLockPermissions];
}

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler {
    [self preflightCheck];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSURL *fileManagerURL = [self  sharedDir];
    
    NSURL *configFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/dnscrypt.toml"];
    
    NSURL *logFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/logs/dns.log"];
    if([fileManager fileExistsAtPath:[logFile path]]) {
        [fileManager removeItemAtPath:[logFile path] error:nil];
    }
    
    NSURL *nxLogFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/logs/nx.log"];
    if([fileManager fileExistsAtPath:[nxLogFile path]]) {
        [fileManager removeItemAtPath:[nxLogFile path] error:nil];
    }
    
    NSURL *queryLogFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/logs/query.log"];
    if([fileManager fileExistsAtPath:[queryLogFile path]]) {
        [fileManager removeItemAtPath:[queryLogFile path] error:nil];
    }
    
    NSURL *blockedLogFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/logs/blocked.log"];
    if([fileManager fileExistsAtPath:[blockedLogFile path]]) {
        [fileManager removeItemAtPath:[blockedLogFile path] error:nil];
    }
    
    NSURL *whiteLogFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/logs/whitelist.log"];
    if([fileManager fileExistsAtPath:[whiteLogFile path]]) {
        [fileManager removeItemAtPath:[whiteLogFile path] error:nil];
    }
    
    __weak typeof(self) weakSelf = self;
    
    if(![fileManager fileExistsAtPath:[configFile path]]) {
        if (@available(iOS 12, *)) {
        } else if (@available(iOS 10, *)) {
            [self displayMessage:@"No configuration file found. Please, use the app to relaunch DNSCrypt client." completionHandler:^(BOOL success) {}];
        }
        
        NEPacketTunnelNetworkSettings *networkSettings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress: @"127.0.0.1" ];
        
        [self setTunnelNetworkSettings:networkSettings completionHandler:^(NSError * _Nullable error) {
            if (error) {
                completionHandler(error);
            } else {
                completionHandler(nil);
            }
        }];
    } else {
        NSUserDefaults *defs = [self sharedDefs];
        
        NSString *net_type = [defs stringForKey:@"netType"];
        
        if (net_type == nil) { //IPv4 by default
            net_type = @"2";
        }
        
        _reach = [Reachability reachabilityForInternetConnection];
        
        [[NSNotificationCenter defaultCenter] addObserver:weakSelf selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];
        
        NEPacketTunnelNetworkSettings *networkSettings = [self getNetworkSettings];
        
        BOOL skipWaitResolvers = [defs boolForKey:@"skipWaitResolvers"];
        
        if (![_reach isReachable] || [_reach isConnectionRequired]) {
            skipWaitResolvers = YES;
        }
        
        NSMutableArray<NSString *> *args = [@[
                                              [configFile path]
                                              ] mutableCopy];
        
        _dns = [[DNSCryptThread alloc] initWithArguments:[args copy]];
        
        if (skipWaitResolvers) {
            [self startProxy];
            [_dns logNotice:@"Skipping available resolvers check, tell iOS we are ready"];
            
            [self setTunnelNetworkSettings:networkSettings completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    completionHandler(error);
                } else {
                    _lastForcedResolversCheck = [NSDate date];
                    [weakSelf.reach startNotifier];
                    completionHandler(nil);
                }
            }];
        } else {
            NSNotificationCenter * __weak center = [NSNotificationCenter defaultCenter];
            id __block token = [center addObserverForName:kDNSCryptProxyReady
                                                   object:nil
                                                    queue:[NSOperationQueue mainQueue]
                                               usingBlock:^(NSNotification *note) {
                                                   [center removeObserver:token];
                                                   
                                                   [_dns logInfo:@"Found available resolvers, tell iOS we are ready"];
                                                   
                                                   [self setTunnelNetworkSettings:networkSettings completionHandler:^(NSError * _Nullable error) {
                                                       if (error) {
                                                           completionHandler(error);
                                                       } else {
                                                           _lastForcedResolversCheck = [NSDate date];
                                                           [weakSelf.reach startNotifier];
                                                           completionHandler(nil);
                                                       }
                                                   }];
                                               }];
            [self startProxy];
            [_dns logInfo:@"Waiting for available resolvers check."];
        }
    }
}

- (void)startProxy {
    [_dns start];
    [_dns logInfo:[NSString stringWithFormat:@"Current reachability is [%@]", [_reach currentReachabilityFlags]]];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    [_reach stopNotifier];
    //[_dns stopApp];
    completionHandler();
    exit(EXIT_SUCCESS);
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler {
    completionHandler();
}

- (void)wake {
    BOOL ok = YES;
    
    if (_lastForcedResolversCheck) {
        NSDate *curTime = [NSDate date];
        if ([curTime timeIntervalSinceDate:_lastForcedResolversCheck] < 60.0)
            ok = NO;
    }
    
    if (ok)
        [self reactivateTunnel: NO];
}

- (void)reachabilityChanged:(NSNotification *)note {
    Reachability *r = (Reachability*) note.object;
    [_dns logInfo:[NSString stringWithFormat:@"Reachability changed to [%@]", [r currentReachabilityFlags]]];
    
    if ([r isReachable] && ![r isConnectionRequired]) {
        NSUserDefaults *defs = [self sharedDefs];
        NSString *net_type = [defs stringForKey:@"netType"];
        
        if (net_type != nil && [net_type isEqualToString:@""]) {
            [_dns logInfo:@"Network connection has changed, refreshing network extension settings and servers info"];
            [self reactivateTunnel:NO];
        } else {
            [_dns logInfo:@"Network connection has changed, refreshing servers info"];
            BOOL skipWaitResolvers = [defs boolForKey:@"skipWaitResolvers"];
            
            if (!skipWaitResolvers) self.reasserting = YES;
            [self refreshServers];
            if (!skipWaitResolvers) self.reasserting = NO;
        }
    }
}

- (void)refreshServers {
    [_dns closeIdleConnections];
    [_dns refreshServersInfo];
}

- (void)reactivateTunnel:(BOOL)isInitialize {
    __weak typeof(self) weakSelf = self;
    self.reasserting = YES;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSURL *fileManagerURL = [self sharedDir];
    
    NSURL *configFile = [fileManagerURL URLByAppendingPathComponent: @"dnscrypt/dnscrypt.toml"];
    
    if(![fileManager fileExistsAtPath:[configFile path]]) {
        if (@available(iOS 12, *)) {
        } else if (@available(iOS 10, *)) {
            [self displayMessage:@"No configuration file found. Please, use the app to relaunch DNSCrypt client." completionHandler:^(BOOL success) {}];
        }
        
        NEPacketTunnelNetworkSettings *networkSettings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress: @"127.0.0.1" ];
        
        [self setTunnelNetworkSettings:networkSettings completionHandler:^(NSError * _Nullable error) {
            weakSelf.reasserting = NO;
        }];
    } else {
        NSUserDefaults *defs = [self sharedDefs];
        BOOL skipWaitResolvers = [defs boolForKey:@"skipWaitResolvers"];
        
        if (!skipWaitResolvers) {
            [self refreshServers];
        }
        
        NEPacketTunnelNetworkSettings *networkSettings = [self getNetworkSettings];
        
        _lastForcedResolversCheck = [NSDate date];
        
        [self setTunnelNetworkSettings:networkSettings completionHandler:^(NSError * _Nullable error) {
            weakSelf.reasserting = NO;
            
            if (skipWaitResolvers) {
                [weakSelf refreshServers];
            }
        }];
    }
}

- (NEPacketTunnelNetworkSettings *)getNetworkSettings {
    NSUserDefaults *defs = [self sharedDefs];
    
    BOOL hasIPv4 = NO;
    BOOL hasIPv6 = NO;
    
    NSString *net_type = [defs stringForKey:@"netType"];
    
    if (net_type == nil) { //IPv4 by default
        net_type = @"2";
    }
    
    if ([net_type isEqualToString:@"1"]) {
        hasIPv6 = YES;
        hasIPv4 = YES;
    } else if ([net_type isEqualToString:@"2"]) {
        hasIPv4 = YES;
    } else if ([net_type isEqualToString:@"3"]) {
        hasIPv6 = YES;
    } else {
        NSInteger net_status = [NetTester status];
        if (net_status == NET_TESTER_IPV6_CONN) {
            hasIPv6 = YES;
        } else if (net_status == NET_TESTER_DUAL_CONN) {
            hasIPv6 = YES;
            hasIPv4 = YES;
        } else {
            hasIPv4 = YES;
        }
    }
    
    NEPacketTunnelNetworkSettings *networkSettings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress: hasIPv6 ? @"::1" : @"127.0.0.1" ];
    
    BOOL showIcon = [defs boolForKey:@"showIcon"];
    
    if (showIcon) {
        if (hasIPv4) {
            NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"192.0.2.1"] subnetMasks:@[@"255.255.255.0"]];
            networkSettings.IPv4Settings = ipv4Settings;
        }
        
        if (hasIPv6) {
            NEIPv6Settings *ipv6Settings = [[NEIPv6Settings alloc] initWithAddresses:@[@"fdc1:c10:ac:1::1"] networkPrefixLengths:@[@(64)]];
            networkSettings.IPv6Settings = ipv6Settings;
        }
    }
    
    NEDNSSettings *dnsSettings;
    if (hasIPv4 && hasIPv6) {
        dnsSettings = [[NEDNSSettings alloc] initWithServers: @[@"127.0.0.1", @"::1"]];
    } else if (hasIPv6) {
        dnsSettings = [[NEDNSSettings alloc] initWithServers: @[@"::1"]];
    } else {
        dnsSettings = [[NEDNSSettings alloc] initWithServers: @[@"127.0.0.1"]];
    }
    
    dnsSettings.matchDomains = @[@""];
    networkSettings.DNSSettings = dnsSettings;
    
    return networkSettings;
}

- (void)logDebug:(NSString *)str {
    [_dns logDebug:str];
}

- (void)logInfo:(NSString *)str {
    [_dns logInfo:str];
}

- (void)logNotice:(NSString *)str {
    [_dns logNotice:str];
}

- (void)logWarn:(NSString *)str {
    [_dns logWarn:str];
}

- (void)logError:(NSString *)str {
    [_dns logError:str];
}

- (void)logCritical:(NSString *)str {
    [_dns logCritical:str];
}

- (void)logFatal:(NSString *)str {
    [_dns logFatal:str];
}

@end
