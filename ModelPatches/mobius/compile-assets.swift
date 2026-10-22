import Foundation
import CoreML
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let out=URL(fileURLWithPath:CommandLine.arguments[2])
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
for width in [16,256] {
 let compiled=try MLModel.compileModel(at:root.appending(path:"prefill-\(width).mlpackage"))
 try FileManager.default.copyItem(at:compiled,to:out.appending(path:"PocketConditioning\(width).mlmodelc"))
}
