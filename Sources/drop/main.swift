import DropCLI
import Foundation

exit(DropCLI.run(Array(CommandLine.arguments.dropFirst()), context: .live()))
