#import "ReactNativePayments.h"
#import <React/RCTUtils.h>
#import <React/RCTEventDispatcher.h>

@implementation ReactNativePayments
@synthesize bridge = _bridge;

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

- (NSDictionary *)constantsToExport
{
    return @{
             @"canMakePayments": @([PKPaymentAuthorizationViewController canMakePayments]),
             @"supportedGateways": [GatewayManager getSupportedGateways]
             };
}

RCT_EXPORT_METHOD(createPaymentRequest: (NSDictionary *)methodData
                  details: (NSDictionary *)details
                  countryData: (NSDictionary *) countryData
                  options: (NSDictionary *)options
                  callback: (RCTResponseSenderBlock)callback)
{
    NSString *merchantId = methodData[@"merchantIdentifier"];
    NSDictionary *gatewayParameters = methodData[@"paymentMethodTokenizationParameters"][@"parameters"];
    
    if (gatewayParameters) {
        self.hasGatewayParameters = true;
        self.gatewayManager = [GatewayManager new];
        [self.gatewayManager configureGateway:gatewayParameters merchantIdentifier:merchantId];
    }
    
    self.paymentRequest = [[PKPaymentRequest alloc] init];
    self.paymentRequest.merchantIdentifier = merchantId;
    self.paymentRequest.merchantCapabilities = PKMerchantCapability3DS;
    self.paymentRequest.countryCode = methodData[@"countryCode"];
    self.paymentRequest.currencyCode = methodData[@"currencyCode"];
    self.paymentRequest.supportedNetworks = [self getSupportedNetworksFromMethodData:methodData];
    self.paymentRequest.paymentSummaryItems = [self getPaymentSummaryItemsFromDetails:details];
    self.paymentRequest.shippingMethods = [self getShippingMethodsFromDetails:details];
    
    [self setRequiredShippingAddressFieldsFromOptions:options];
    
    // Set options so that we can later access it.
    self.initialOptions = options;
    
    self.countryData = countryData;
    
    callback(@[[NSNull null]]);
}

RCT_EXPORT_METHOD(show:(RCTResponseSenderBlock)callback)
{
    
    self.viewController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest: self.paymentRequest];
    self.viewController.delegate = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *rootViewController = RCTPresentedViewController();
        [rootViewController presentViewController:self.viewController animated:YES completion:nil];
        callback(@[[NSNull null]]);
    });
}

RCT_EXPORT_METHOD(abort: (RCTResponseSenderBlock)callback)
{
    [self.viewController dismissViewControllerAnimated:YES completion:nil];
    
    callback(@[[NSNull null]]);
}

RCT_EXPORT_METHOD(complete: (NSString *)paymentStatus
                  callback: (RCTResponseSenderBlock)callback)
{
    if(@available(iOS 11.0, *)){
        if ([paymentStatus isEqualToString: @"success"]) {
            self.resultCompletion([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusSuccess errors:nil]);
        } else {
            self.resultCompletion([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusFailure errors:nil]);
        }
    }
    else {
        if ([paymentStatus isEqualToString: @"success"]) {
            self.completion(PKPaymentAuthorizationStatusSuccess);
        } else {
            self.completion(PKPaymentAuthorizationStatusFailure);
        }
    }
    callback(@[[NSNull null]]);
}


-(void) paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller
{
    [controller dismissViewControllerAnimated:YES completion:nil];
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onuserdismiss" body:nil];
}

RCT_EXPORT_METHOD(handleDetailsUpdate: (NSDictionary *)details
                  callback: (RCTResponseSenderBlock)callback)

{
    if (!self.shippingContactCompletion && !self.shippingMethodCompletion) {
        // TODO:
        // - Call callback with error saying shippingContactCompletion was never called;
        
        return;
    }
    
    NSArray<PKShippingMethod *> * shippingMethods = [self getShippingMethodsFromDetails:details];
    
    NSArray<PKPaymentSummaryItem *> * paymentSummaryItems = [self getPaymentSummaryItemsFromDetails:details];
    
    
    if (self.shippingMethodCompletion) {
        self.shippingMethodCompletion(
                                      PKPaymentAuthorizationStatusSuccess,
                                      paymentSummaryItems
                                      );
        
        // Invalidate `self.shippingMethodCompletion`
        self.shippingMethodCompletion = nil;
    }
    
    if (self.shippingContactCompletion) {
        // Display shipping address error when shipping is needed and shipping method count is below 1
        if (self.initialOptions[@"requestShipping"] && [shippingMethods count] == 0) {
            return self.shippingContactCompletion(
                                                  PKPaymentAuthorizationStatusInvalidShippingPostalAddress,
                                                  shippingMethods,
                                                  paymentSummaryItems
                                                  );
        } else {
            self.shippingContactCompletion(
                                           PKPaymentAuthorizationStatusSuccess,
                                           shippingMethods,
                                           paymentSummaryItems
                                           );
        }
        // Invalidate `aself.shippingContactCompletion`
        self.shippingContactCompletion = nil;
        
    }
    
    // Call callback
    callback(@[[NSNull null]]);
    
}

-(void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller didAuthorizePayment:(PKPayment *)payment handler:(void (^)(PKPaymentAuthorizationResult * _Nonnull))completion API_AVAILABLE(ios(11.0)){
    
    NSString *countryName = payment.shippingContact.postalAddress.country;
    NSString *stateName = payment.shippingContact.postalAddress.state;
    
    NSString *currentCountryName = [self.countryData objectForKey:@"countryName"];
    NSArray *currentCountryStates = [self.countryData objectForKey:@"state"];
    
    NSString *phoneNumber = [payment.shippingContact.phoneNumber.stringValue stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSString *mobileCountryCode = [NSString stringWithFormat:@"%@", [self.countryData objectForKey:@"mobileCountryCode"]];
    NSString *mobileLocalCode = [NSString stringWithFormat:@"%@", [self.countryData objectForKey:@"mobileLocalCode"]];
    NSInteger mobileLocalNumberLength = [[self.countryData objectForKey:@"mobileLocalNumberLength"] integerValue];
    
    NSMutableArray<NSError*> *errors = [[NSMutableArray alloc] init];
    if(![countryName.lowercaseString isEqualToString:currentCountryName.lowercaseString]){
        [errors addObject:[PKPaymentRequest paymentShippingAddressInvalidErrorWithKey:CNPostalAddressCountryKey localizedDescription:@"Selected country is not supported"]];
    }
    
    if(currentCountryStates && [currentCountryStates isKindOfClass:[NSArray class]]){
        BOOL isInvalidState = [currentCountryStates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *  _Nullable  evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
            NSString *evaluatesStateName = evaluatedObject[@"StateName"];
            return [stateName.lowercaseString isEqualToString:evaluatesStateName.lowercaseString];
        }]].count == 0;
        
        if(isInvalidState){
            [errors addObject:[PKPaymentRequest paymentShippingAddressInvalidErrorWithKey:CNPostalAddressStateKey localizedDescription:@"State is invalid"]];
        }
    }
    
    __block NSInteger maxMobileLocalCodeLength = 0;
    
    NSArray *mobileLocalCodes;
    if(mobileLocalCode && [mobileLocalCode length] > 0){
        mobileLocalCodes = [mobileLocalCode componentsSeparatedByString:@","];
        [mobileLocalCodes enumerateObjectsUsingBlock:^(NSString  * _Nonnull mobileLocalCode, NSUInteger idx, BOOL * _Nonnull stop) {
            
            if(mobileLocalCode.length > maxMobileLocalCodeLength){
                maxMobileLocalCodeLength = mobileLocalCode.length;
            }
        }];
    }
    
    NSInteger mobileCountryCodeLength = [mobileCountryCode length];
    NSInteger maxMobileLength = mobileCountryCodeLength + maxMobileLocalCodeLength + mobileLocalNumberLength + 1;
    
    NSString *firstChar =  [phoneNumber substringWithRange: NSMakeRange(0, 1)];
    
    NSString *countryCodeNumber =  @"";
    if([phoneNumber length] > mobileCountryCodeLength + 1){
        countryCodeNumber = [phoneNumber substringWithRange: NSMakeRange(1, mobileCountryCodeLength)];
    }
    NSString *localCodeNumber = @"";
    if([phoneNumber length] > (mobileCountryCodeLength + 1 + maxMobileLocalCodeLength)) {
        localCodeNumber = [phoneNumber substringWithRange: NSMakeRange(mobileCountryCodeLength + 1, maxMobileLocalCodeLength)];
    }
    
    BOOL isValidLocalCode = [mobileLocalCodes containsObject:localCodeNumber];
    
    if(([phoneNumber length] < maxMobileLength) || !([firstChar isEqualToString:@"+"] && [countryCodeNumber isEqualToString:mobileCountryCode] && isValidLocalCode && [phoneNumber length] == maxMobileLength)){
        
        NSString *desc = [NSString stringWithFormat:@"Phone number must start with +%@(%@)", mobileCountryCode, mobileLocalCode];
        
        NSInteger i = 0;
        while(i < mobileLocalNumberLength) {
            desc = [desc stringByAppendingFormat:@"X"];
            i++;
        }
        [errors addObject:[PKPaymentRequest paymentContactInvalidErrorWithContactField:PKContactFieldPhoneNumber localizedDescription: desc]];
    }
    
    if([errors count] > 0){
        completion([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusFailure errors:errors]);
    }
    else {
        // Store completion for later use
        self.resultCompletion = completion;
        
        if (self.hasGatewayParameters) {
            [self.gatewayManager createTokenWithPayment:payment completion:^(NSString * _Nullable token, NSError * _Nullable error) {
                if (error) {
                    [self handleGatewayError:error];
                    return;
                }
                
                [self handleUserAccept:payment paymentToken:token];
            }];
        } else {
            [self handleUserAccept:payment paymentToken:nil];
        }
    }
}

- (void) paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                        didAuthorizePayment:(PKPayment *)payment
                                 completion:(void (^)(PKPaymentAuthorizationStatus))completion
{

    self.completion = completion;

    if (self.hasGatewayParameters) {
        [self.gatewayManager createTokenWithPayment:payment completion:^(NSString * _Nullable token, NSError * _Nullable error) {
            if (error) {
                [self handleGatewayError:error];
                return;
            }

            [self handleUserAccept:payment paymentToken:token];
        }];
    } else {
        [self handleUserAccept:payment paymentToken:nil];
    }
}


// Shipping Contact
- (void) paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                   didSelectShippingContact:(PKContact *)contact
                                 completion:(nonnull void (^)(PKPaymentAuthorizationStatus, NSArray<PKShippingMethod *> * _Nonnull, NSArray<PKPaymentSummaryItem *> * _Nonnull))completion
{
    
    
    self.shippingContactCompletion = completion;
    
    CNPostalAddress *postalAddress = contact.postalAddress;
    // street, subAdministrativeArea, and subLocality are supressed for privacy
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onshippingaddresschange"
                                                    body:@{
                                                           @"recipient": [NSNull null],
                                                           @"organization": [NSNull null],
                                                           @"addressLine": [NSNull null],
                                                           @"city": postalAddress.city,
                                                           @"region": postalAddress.state,
                                                           @"country": [postalAddress.ISOCountryCode uppercaseString],
                                                           @"postalCode": postalAddress.postalCode,
                                                           @"phone": [NSNull null],
                                                           @"languageCode": [NSNull null],
                                                           @"sortingCode": [NSNull null],
                                                           @"dependentLocality": [NSNull null]
                                                           }];
}

// Shipping Method delegates
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                   didSelectShippingMethod:(PKShippingMethod *)shippingMethod
                                completion:(void (^)(PKPaymentAuthorizationStatus, NSArray<PKPaymentSummaryItem *> * _Nonnull))completion
{
    self.shippingMethodCompletion = completion;
    
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onshippingoptionchange" body:@{
                                                                                                         @"selectedShippingOptionId": shippingMethod.identifier
                                                                                                         }];
    
}

// PRIVATE METHODS
// https://developer.apple.com/reference/passkit/pkpaymentnetwork
// ---------------
- (NSArray *_Nonnull)getSupportedNetworksFromMethodData:(NSDictionary *_Nonnull)methodData
{
    NSMutableDictionary *supportedNetworksMapping = [[NSMutableDictionary alloc] init];
    
    CGFloat iOSVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
    
    if (iOSVersion >= 8) {
        [supportedNetworksMapping setObject:PKPaymentNetworkAmex forKey:@"amex"];
        [supportedNetworksMapping setObject:PKPaymentNetworkMasterCard forKey:@"mastercard"];
        [supportedNetworksMapping setObject:PKPaymentNetworkVisa forKey:@"visa"];
    }
    
    if (iOSVersion >= 9) {
        [supportedNetworksMapping setObject:PKPaymentNetworkDiscover forKey:@"discover"];
        [supportedNetworksMapping setObject:PKPaymentNetworkPrivateLabel forKey:@"privatelabel"];
    }
    
    if (iOSVersion >= 9.2) {
        [supportedNetworksMapping setObject:PKPaymentNetworkChinaUnionPay forKey:@"chinaunionpay"];
        [supportedNetworksMapping setObject:PKPaymentNetworkInterac forKey:@"interac"];
    }
    
    if (iOSVersion >= 10.1) {
        [supportedNetworksMapping setObject:PKPaymentNetworkJCB forKey:@"jcb"];
        [supportedNetworksMapping setObject:PKPaymentNetworkSuica forKey:@"suica"];
    }
    
    if (iOSVersion >= 10.3) {
        [supportedNetworksMapping setObject:PKPaymentNetworkCarteBancaire forKey:@"cartebancaires"];
        [supportedNetworksMapping setObject:PKPaymentNetworkIDCredit forKey:@"idcredit"];
        [supportedNetworksMapping setObject:PKPaymentNetworkQuicPay forKey:@"quicpay"];
    }
    
    if (iOSVersion >= 11) {
        [supportedNetworksMapping setObject:PKPaymentNetworkCarteBancaires forKey:@"cartebancaires"];
    }
    
    // Setup supportedNetworks
    NSArray *jsSupportedNetworks = methodData[@"supportedNetworks"];
    NSMutableArray *supportedNetworks = [NSMutableArray array];
    for (NSString *supportedNetwork in jsSupportedNetworks) {
        [supportedNetworks addObject: supportedNetworksMapping[supportedNetwork]];
    }
    
    return supportedNetworks;
}

- (NSArray<PKPaymentSummaryItem *> *_Nonnull)getPaymentSummaryItemsFromDetails:(NSDictionary *_Nonnull)details
{
    // Setup `paymentSummaryItems` array
    NSMutableArray <PKPaymentSummaryItem *> * paymentSummaryItems = [NSMutableArray array];
    
    // Add `displayItems` to `paymentSummaryItems`
    NSArray *displayItems = details[@"displayItems"];
    if (displayItems.count > 0) {
        for (NSDictionary *displayItem in displayItems) {
            [paymentSummaryItems addObject: [self convertDisplayItemToPaymentSummaryItem:displayItem]];
        }
    }
    
    // Add total to `paymentSummaryItems`
    NSDictionary *total = details[@"total"];
    [paymentSummaryItems addObject: [self convertDisplayItemToPaymentSummaryItem:total]];
    
    return paymentSummaryItems;
}

- (NSArray<PKShippingMethod *> *_Nonnull)getShippingMethodsFromDetails:(NSDictionary *_Nonnull)details
{
    // Setup `shippingMethods` array
    NSMutableArray <PKShippingMethod *> * shippingMethods = [NSMutableArray array];
    
    // Add `shippingOptions` to `shippingMethods`
    NSArray *shippingOptions = details[@"shippingOptions"];
    if (shippingOptions.count > 0) {
        for (NSDictionary *shippingOption in shippingOptions) {
            [shippingMethods addObject: [self convertShippingOptionToShippingMethod:shippingOption]];
        }
    }
    
    return shippingMethods;
}

- (PKPaymentSummaryItem *_Nonnull)convertDisplayItemToPaymentSummaryItem:(NSDictionary *_Nonnull)displayItem;
{
    NSDecimalNumber *decimalNumberAmount = [NSDecimalNumber decimalNumberWithString:displayItem[@"amount"][@"value"]];
    PKPaymentSummaryItem *paymentSummaryItem = [PKPaymentSummaryItem summaryItemWithLabel:displayItem[@"label"] amount:decimalNumberAmount];
    
    return paymentSummaryItem;
}

- (PKShippingMethod *_Nonnull)convertShippingOptionToShippingMethod:(NSDictionary *_Nonnull)shippingOption
{
    PKShippingMethod *shippingMethod = [PKShippingMethod summaryItemWithLabel:shippingOption[@"label"] amount:[NSDecimalNumber decimalNumberWithString: shippingOption[@"amount"][@"value"]]];
    shippingMethod.identifier = shippingOption[@"id"];
    
    // shippingOption.detail is not part of the PaymentRequest spec.
    if ([shippingOption[@"detail"] isKindOfClass:[NSString class]]) {
        shippingMethod.detail = shippingOption[@"detail"];
    } else {
        shippingMethod.detail = @"";
    }
    
    return shippingMethod;
}

- (void)setRequiredShippingAddressFieldsFromOptions:(NSDictionary *_Nonnull)options
{
    // Request Shipping
    if (options[@"requestShipping"]) {
        self.paymentRequest.requiredShippingAddressFields = PKAddressFieldPostalAddress;
    }
    
    if (options[@"requestPayerName"]) {
        self.paymentRequest.requiredShippingAddressFields = self.paymentRequest.requiredShippingAddressFields | PKAddressFieldName;
    }
    
    if (options[@"requestPayerPhone"]) {
        self.paymentRequest.requiredShippingAddressFields = self.paymentRequest.requiredShippingAddressFields | PKAddressFieldPhone;
    }
    
    if (options[@"requestPayerEmail"]) {
        self.paymentRequest.requiredShippingAddressFields = self.paymentRequest.requiredShippingAddressFields | PKAddressFieldEmail;
    }
}

- (void)handleUserAccept:(PKPayment *_Nonnull)payment
            paymentToken:(NSString *_Nullable)token
{
    NSString *transactionId = payment.token.transactionIdentifier;
    NSString *paymentData = [[NSString alloc] initWithData:payment.token.paymentData encoding:NSUTF8StringEncoding];
    NSMutableDictionary *paymentResponse = [[NSMutableDictionary alloc]initWithCapacity:3];
    [paymentResponse setObject:transactionId forKey:@"transactionIdentifier"];
    [paymentResponse setObject:paymentData forKey:@"paymentData"];
                
    PKContact *shippingContact = payment.shippingContact;
    if(shippingContact) {

        NSMutableDictionary *shippingAddress = [NSMutableDictionary new];
        NSPersonNameComponents *presonNameComponent = shippingContact.name;

        if (presonNameComponent) {
            [shippingAddress setObject:presonNameComponent.namePrefix forKey:@"namePrefix"];
            [shippingAddress setObject:presonNameComponent.nameSuffix forKey:@"nameSuffix"];
            [shippingAddress setObject:presonNameComponent.givenName forKey:@"givenName"];
            [shippingAddress setObject:presonNameComponent.middleName forKey:@"middleName"];
            [shippingAddress setObject:presonNameComponent.nickname forKey:@"nickname"];
            [shippingAddress setObject:presonNameComponent.familyName forKey:@"familyName"];
        }

        CNPostalAddress *postalAddess = shippingContact.postalAddress;
        if (postalAddess) {
            [shippingAddress setObject:postalAddess.street forKey:@"street"];
            [shippingAddress setObject:postalAddess.city forKey:@"city"];
            [shippingAddress setObject:postalAddess.state forKey:@"state"];
            [shippingAddress setObject:postalAddess.postalCode forKey:@"postalCode"];
            [shippingAddress setObject:postalAddess.country forKey:@"country"];
            [shippingAddress setObject:postalAddess.ISOCountryCode forKey:@"countryCode"];
        }
        
        [shippingAddress setObject:shippingContact.emailAddress forKey:@"email"];

        
        CNPhoneNumber *phoneNumber = shippingContact.phoneNumber;
        if (postalAddess) {
            [shippingAddress setObject:phoneNumber.stringValue forKey:@"phoneNumber"];
        }

        [paymentResponse setObject:shippingAddress forKey:@"userAddress"];
    }
    
    if (token) {
        [paymentResponse setObject:token forKey:@"paymentToken"];
    }
    
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onuseraccept"
                                                    body:paymentResponse
     ];
}

- (void)handleGatewayError:(NSError *_Nonnull)error
{
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:ongatewayerror"
                                                    body: @{
                                                            @"error": [error localizedDescription]
                                                            }
     ];
}

@end
