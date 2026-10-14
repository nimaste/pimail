/// What the server says about bytes it has just taken.
///
/// The `blobId` is the only part worth keeping: it is what names those bytes
/// in a later `Email/set` create. Opaque by spec, and never parsed.
public struct UploadedBlob: Decodable, Sendable {
    public var accountID: AccountID
    public var blobID: BlobID
    public var type: String
    public var size: Int

    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case blobID = "blobId"
        case type, size
    }
}
