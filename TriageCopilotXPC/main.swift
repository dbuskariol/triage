import Foundation

let listener = NSXPCListener.service()
let delegate = TriageCopilotXPCListener()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
