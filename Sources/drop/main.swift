import DropCLI
import Foundation

exit(await DropCLI.runAsync(Array(CommandLine.arguments.dropFirst()), context: .live()))
