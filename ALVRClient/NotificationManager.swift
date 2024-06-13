import Foundation
import Combine
import QuartzCore

class NotificationManager: ObservableObject {
    @Published var message: String? = nil
    
    var lastTime = 0.0
    var xRaw: UInt32 = 0
    var xBits = 0
    var xFloat: Float = 0.0
    
    var yRaw: UInt32 = 0
    var yBits = 0
    var yFloat: Float = 0.0
    
    func updateSingleton() {
        if self.xFloat < 0.0 {
            self.xFloat = 0.0
        }
        if self.xFloat > 1.0 {
            self.xFloat = 1.0
        }
        
        if self.yFloat < 0.0 {
            self.yFloat = 0.0
        }
        if self.yFloat > 1.0 {
            self.yFloat = 1.0
        }
        
        WorldTracker.shared.eyeX = (self.xFloat - 0.5) * 1.0
        WorldTracker.shared.eyeY = ((1.0 - self.yFloat) - 0.5) * 1.0
    }

    init() {
        print("NotificationManager init")
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            //print("notification!", name, object, userInfo)
            
            let notificationManager = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            notificationManager.xRaw = 0
            notificationManager.xBits = 0
        }, "EyeTrackingInfoXStart" as CFString, nil, .deliverImmediately)
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let notificationManager = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            notificationManager.xRaw >>= 1
            notificationManager.xRaw |= 0
            notificationManager.xBits += 1
            
            if notificationManager.xBits >= 32 {
                notificationManager.xFloat = Float(bitPattern: notificationManager.xRaw)
                //notificationManager.updateSingleton()
            }
        }, "EyeTrackingInfoX0" as CFString, nil, .deliverImmediately)
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let notificationManager = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            notificationManager.xRaw >>= 1
            notificationManager.xRaw |= 0x80000000
            notificationManager.xBits += 1
            
            if notificationManager.xBits >= 32 {
                notificationManager.xFloat = Float(bitPattern: notificationManager.xRaw)
                //notificationManager.updateSingleton()
            }
        }, "EyeTrackingInfoX1" as CFString, nil, .deliverImmediately)
        
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            //print("notification!", name, object, userInfo)
            
            let notificationManager = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            notificationManager.yRaw = 0
            notificationManager.yBits = 0
        }, "EyeTrackingInfoYStart" as CFString, nil, .deliverImmediately)
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let notificationManager = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            notificationManager.yRaw >>= 1
            notificationManager.yRaw |= 0
            notificationManager.yBits += 1
            
            if notificationManager.yBits >= 32 {
                notificationManager.yFloat = Float(bitPattern: notificationManager.yRaw)
                notificationManager.updateSingleton()
            }
        }, "EyeTrackingInfoY0" as CFString, nil, .deliverImmediately)
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let notificationManager = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            notificationManager.yRaw >>= 1
            notificationManager.yRaw |= 0x80000000
            notificationManager.yBits += 1
            
            if notificationManager.yBits >= 32 {
                notificationManager.yFloat = Float(bitPattern: notificationManager.yRaw)
                notificationManager.updateSingleton()
            }
        }, "EyeTrackingInfoY1" as CFString, nil, .deliverImmediately)
    }

    deinit {
        print("NotificationManager deinit")
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque())
    }
}
