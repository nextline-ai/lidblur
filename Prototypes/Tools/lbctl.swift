// lbctl — send debug commands to BlurLab: lbctl progress 0.7 | lbctl mode sensor
import Foundation
let a = CommandLine.arguments
guard a.count == 3 else { print("usage: lbctl progress <0..1> | mode <manual|sensor> | snapshot <path.png>"); exit(1) }
DistributedNotificationCenter.default().postNotificationName(Notification.Name("studio.xtower.lidblur.debug"), object: nil, userInfo: [a[1]: a[2]], deliverImmediately: true)
