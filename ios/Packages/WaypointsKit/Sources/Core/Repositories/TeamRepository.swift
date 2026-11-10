import Foundation

/// `teams`, `team_roles`, `team_members`, `channels`. Section 5.4.
public protocol TeamRepository: Sendable {
    func myTeams() async throws -> [Team]
    func team(_ id: TeamID) async throws -> Team
    func publicTeams(matching query: String?) async throws -> [Team]
    /// Creates the team with roles "Owner" and "Member" and channels `general` and `Garage`.
    @discardableResult func createTeam(_ draft: TeamDraft) async throws -> Team
    @discardableResult func updateTeam(_ team: Team) async throws -> Team
    func deleteTeam(_ id: TeamID) async throws
    /// RPC `join_team(code)`.
    @discardableResult func join(code: String) async throws -> Team
    func joinPublic(_ id: TeamID) async throws
    func leave(_ id: TeamID) async throws

    func members(of team: TeamID) async throws -> [TeamMember]
    func roles(of team: TeamID) async throws -> [TeamRole]
    @discardableResult func saveRole(_ role: TeamRole) async throws -> TeamRole
    func deleteRole(_ id: TeamRoleID) async throws
    func assign(_ role: TeamRoleID?, to user: UserID, in team: TeamID) async throws
    func kick(_ user: UserID, from team: TeamID) async throws
    func myPermissions(in team: TeamID) async throws -> TeamPermissions

    func channels(of team: TeamID) async throws -> [Channel]
    func channel(_ id: ChannelID) async throws -> Channel
    @discardableResult func saveChannel(_ channel: Channel) async throws -> Channel
    func deleteChannel(_ id: ChannelID) async throws
}
