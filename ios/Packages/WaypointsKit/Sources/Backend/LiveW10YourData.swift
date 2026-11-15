import Core
import Foundation
import Supabase

/// ACC-12: the `export_my_data` RPC, returned as the raw JSON it sends.
extension LiveProfiles {
    func exportMyData() async throws -> Data {
        try await ctx.run {
            try await ctx.client.rpc("export_my_data").execute().data
        }
    }
}
