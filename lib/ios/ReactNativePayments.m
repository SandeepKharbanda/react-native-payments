#import "ReactNativePayments.h"
#import <React/RCTUtils.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>

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
                  requestedData: (NSDictionary *) requestedData
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
    
    self.options = options;
    [self setRequiredShippingAddressFieldsFromOptions:options];
    
    PKContact *contact = [[PKContact alloc] init];
    if (options[@"requestShipping"]) {
        CNMutablePostalAddress *address = [[CNMutablePostalAddress alloc] init];
        NSDictionary *shippingAddress = requestedData[@"shippingInfo"];
        if (shippingAddress && [shippingAddress isKindOfClass:[NSDictionary class]]) {
            address.street = shippingAddress[@"street"];
            address.city = shippingAddress[@"city"];
            address.country = shippingAddress[@"country"];
            address.ISOCountryCode = shippingAddress[@"ISOCountryCode"];
            address.state = shippingAddress[@"state"];
            address.postalCode = shippingAddress[@"postalCode"];
            contact.postalAddress = address;
        }
    }
    
    NSDictionary *phoneNumberInfo = requestedData[@"phoneNumberInfo"];
    if (options[@"requestPayerPhone"] && phoneNumberInfo && [phoneNumberInfo isKindOfClass:[NSDictionary class]]) {
        NSString *phoneNumber = [phoneNumberInfo objectForKey:@"phone"];
        if(phoneNumber && [phoneNumber length] > 0){
            contact.phoneNumber = [CNPhoneNumber phoneNumberWithStringValue:phoneNumber];
        }
    }
    
    NSDictionary *personInfo = requestedData[@"personInfo"];
    if (personInfo && [personInfo isKindOfClass:[NSDictionary class]]) {
        NSPersonNameComponents *name = [[NSPersonNameComponents alloc] init];
        name.givenName = personInfo[@"givenName"];
        name.middleName = personInfo[@"middleName"];
        name.familyName = personInfo[@"familyName"];
        contact.name = name;
    }
    self.paymentRequest.shippingContact = contact;
    
    // Set options so that we can later access it.
    self.initialOptions = options;
    
    self.countryData = requestedData[@"country"];
    
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
    
    NSMutableArray<NSError*> *errors = [[NSMutableArray alloc] init];
    
    if (self.options[@"requestShipping"]) {
        NSString *ISOCountryCode = payment.shippingContact.postalAddress.ISOCountryCode;
        NSString *stateName = payment.shippingContact.postalAddress.state;
        
        NSString *currentCountryCode = [self.countryData objectForKey:@"countrySHORT"];
        NSArray *currentCountryStates = [self.countryData objectForKey:@"state"];
        if(currentCountryCode && [currentCountryCode length] > 0 && ![ISOCountryCode.lowercaseString isEqualToString:currentCountryCode.lowercaseString]){
            [errors addObject:[PKPaymentRequest paymentShippingAddressInvalidErrorWithKey:CNPostalAddressCountryKey localizedDescription:@"Selected country is not supported"]];
        }
        
        if(stateName && [stateName length] > 0 && currentCountryStates && [currentCountryStates isKindOfClass:[NSArray class]]){
            BOOL isInvalidState = [currentCountryStates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *  _Nullable  evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
                NSString *evaluatesStateName = evaluatedObject[@"StateName"];
                return [stateName.lowercaseString isEqualToString:evaluatesStateName.lowercaseString];
            }]].count == 0;
            
            if(isInvalidState){
                [errors addObject:[PKPaymentRequest paymentShippingAddressInvalidErrorWithKey:CNPostalAddressStateKey localizedDescription:@"State is invalid"]];
            }
        }
    }
        
    
    if (self.options[@"requestPayerPhone"]) {
        
        NSString *phoneNumber = payment.shippingContact.phoneNumber.stringValue;
        NSMutableCharacterSet *characterSet =
        [NSMutableCharacterSet characterSetWithCharactersInString:@"()- "];
        NSArray *arrayOfComponents = [phoneNumber componentsSeparatedByCharactersInSet:characterSet];
        phoneNumber = [arrayOfComponents componentsJoinedByString:@""];
        
        NSString *mobileLocalCode = [NSString stringWithFormat:@"%@", [self.countryData objectForKey:@"mobileLocalCode"]];
        NSInteger mobileLocalNumberLength = [[self.countryData objectForKey:@"mobileLocalNumberLength"] integerValue];

    
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
        
        NSInteger maxMobileLength = maxMobileLocalCodeLength + mobileLocalNumberLength;
        NSString *localCodeNumber = @"";
        if([phoneNumber length] > maxMobileLocalCodeLength) {
            localCodeNumber = [phoneNumber substringWithRange: NSMakeRange(0, maxMobileLocalCodeLength)];
        }
        
        BOOL isValidLocalCode = [mobileLocalCodes containsObject:localCodeNumber];
        
        if(([phoneNumber length] < maxMobileLength) || !( isValidLocalCode && [phoneNumber length] == maxMobileLength)){
            
            NSString *desc = [NSString stringWithFormat:@"Phone number must start with (%@)", mobileLocalCode];
            
            NSInteger i = 0;
            while(i < mobileLocalNumberLength) {
                desc = [desc stringByAppendingFormat:@"X"];
                i++;
            }
            [errors addObject:[PKPaymentRequest paymentContactInvalidErrorWithContactField:PKContactFieldPhoneNumber localizedDescription: desc]];
        }
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
    NSMutableDictionary *paymentResponse = [[NSMutableDictionary alloc] init];
    [paymentResponse setObject:transactionId forKey:@"transactionIdentifier"];
    [paymentResponse setObject:paymentData forKey:@"paymentData"];
    
    PKPaymentMethod *paymentMethod = payment.token.paymentMethod;
    if(paymentMethod){
        NSMutableDictionary *paymentMethodResponse = [[NSMutableDictionary alloc]init];
        [paymentMethodResponse setObject:paymentMethod.displayName forKey:@"displayName"];
        [paymentMethodResponse setObject:paymentMethod.network forKey:@"network"];
        
        NSString *type = @"";
        switch (paymentMethod.type) {
            case PKPaymentMethodTypeDebit:
                type = @"debit";
                break;
            case PKPaymentMethodTypeCredit:
                type = @"credit";
                break;
            case PKPaymentMethodTypePrepaid:
                type = @"prepaid";
                break;
            case PKPaymentMethodTypeStore:
                type = @"store";
                break;
            default:
                type = @"unknown";
                break;
        }
        [paymentMethodResponse setObject:type forKey:@"type"];
        
        PKPaymentPass *paymentPass = paymentMethod.paymentPass;
        if(paymentPass){
            [paymentMethodResponse setObject:paymentPass.primaryAccountIdentifier forKey:@"primaryAccountIdentifier"];
            [paymentMethodResponse setObject:paymentPass.primaryAccountNumberSuffix forKey:@"primaryAccountNumberSuffix"];
            [paymentMethodResponse setObject:paymentPass.deviceAccountIdentifier forKey:@"deviceAccountIdentifier"];
            [paymentMethodResponse setObject:paymentPass.deviceAccountNumberSuffix forKey:@"deviceAccountNumberSuffix"];
            
            NSString *activationState = @"";
            
            switch (paymentPass.activationState) {
                case PKPaymentPassActivationStateActivated:
                    activationState = @"activated";
                    break;
                case PKPaymentPassActivationStateActivating:
                    activationState = @"activating";
                    break;
                case PKPaymentPassActivationStateSuspended:
                    activationState = @"suspended";
                    break;
                case PKPaymentPassActivationStateDeactivated:
                    activationState = @"deactivated";
                default:
                    break;
            }
            
            [paymentMethodResponse setObject:activationState forKey:@"activationState"];
        }
        
        [paymentResponse setObject:paymentMethodResponse forKey:@"paymentMethod"];
    }
    
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
            [shippingAddress setObject:postalAddess.subAdministrativeArea forKey:@"subAdministrativeArea"];
            [shippingAddress setObject:postalAddess.city forKey:@"city"];
            [shippingAddress setObject:postalAddess.state forKey:@"state"];
            [shippingAddress setObject:postalAddess.postalCode forKey:@"postalCode"];
            [shippingAddress setObject:postalAddess.country forKey:@"country"];
            [shippingAddress setObject:postalAddess.ISOCountryCode forKey:@"countryCode"];
        }
        
        id emailAddress = shippingContact.emailAddress;
        RCTLogInfo(@"emailAddress %@", emailAddress);
        
        if(self.options[@"requestPayerEmail"] && emailAddress && [emailAddress isKindOfClass:[NSString class]] && [emailAddress length] > 0){
            [shippingAddress setObject:emailAddress forKey:@"email"];
        }
        
        CNPhoneNumber *shippingContactPhoneNumber = shippingContact.phoneNumber;
        if (shippingContactPhoneNumber) {
            NSString *phoneNumber = shippingContactPhoneNumber.stringValue;
            NSMutableCharacterSet *characterSet =
            [NSMutableCharacterSet characterSetWithCharactersInString:@"()- "];
            NSArray *arrayOfComponents = [phoneNumber componentsSeparatedByCharactersInSet:characterSet];
            phoneNumber = [arrayOfComponents componentsJoinedByString:@""];
            [shippingAddress setObject:phoneNumber forKey:@"phoneNumber"];
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



