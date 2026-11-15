import Core
import DesignSystem
import SwiftUI

/// TEAM-11: teams ranked by the Showdown votes their members' cars won this week.
struct StandingsView: View {
    let model: TeamsModel
    @State private var list: [TeamStanding]?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Showdown votes won by members' cars since Monday.", bundle: .module)
                    .typeStyle(.foot).foregroundStyle(Color.dust).padding(Space.margin)
                if let list {
                    if list.isEmpty {
                        Text("No votes yet this week.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                            .padding(.horizontal, Space.margin)
                    }
                    ForEach(list) { s in
                        Row(Text(verbatim: s.name), subtitle: Text(verbatim: s.tag), leading: {
                            Text(verbatim: s.rank.formatted(.number)).typeStyle(.readoutS).foregroundStyle(Color.dust)
                                .frame(minWidth: Space.s24)
                                .accessibilityLabel(Text("Rank \(s.rank.formatted(.number))", bundle: .module))
                            TeamIcon(team: Team(id: s.id, ownerID: UserID(), name: s.name, tag: s.tag, iconPath: s.iconPath),
                                     env: model.env, size: Size.hitTarget)
                        }, trailing: {
                            Text(verbatim: s.score.formatted(.number)).typeStyle(.readoutS).foregroundStyle(Color.chalk)
                        })
                    }
                } else if failed {
                    ErrorState(Text("Couldn't load the standings. Check your connection and try again.", bundle: .module)) {
                        Task { await load() }
                    }
                } else {
                    SkeletonRow(); SkeletonRow(); SkeletonRow()
                }
            }
        }
        .refreshable { await load() }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(Text("Standings", bundle: .module))
        .task { await load() }
    }

    private func load() async {
        failed = false
        let found = try? await model.env.teams.standings(including: nil)
        if let found { list = found }
        failed = found == nil && list == nil
    }
}
