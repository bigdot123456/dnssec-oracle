pragma solidity ^0.4.23;

import "./Owned.sol";
import "./Buffer.sol";
import "./BytesUtils.sol";
import "./RRUtils.sol";
import "./Algorithm.sol";
import "./Digest.sol";
import "./NSEC3Digest.sol";

/*
 * @dev An oracle contract that verifies and stores DNSSEC-validated DNS records.
 *
 * TODO: Support for NSEC3 records
 * TODO: Use 'serial number math' for inception/expiration
 */
contract DNSSEC is Owned {
    using Buffer for Buffer.buffer;
    using BytesUtils for bytes;
    using RRUtils for *;

    uint16 constant DNSCLASS_IN = 1;

    uint16 constant DNSTYPE_DS = 43;
    uint16 constant DNSTYPE_RRSIG = 46;
    uint16 constant DNSTYPE_NSEC = 47;
    uint16 constant DNSTYPE_DNSKEY = 48;
    uint16 constant DNSTYPE_NSEC3 = 50;

    uint constant DS_KEY_TAG = 0;
    uint constant DS_ALGORITHM = 2;
    uint constant DS_DIGEST_TYPE = 3;
    uint constant DS_DIGEST = 4;

    uint constant RRSIG_TYPE = 0;
    uint constant RRSIG_ALGORITHM = 2;
    uint constant RRSIG_LABELS = 3;
    uint constant RRSIG_TTL = 4;
    uint constant RRSIG_EXPIRATION = 8;
    uint constant RRSIG_INCEPTION = 12;
    uint constant RRSIG_KEY_TAG = 16;
    uint constant RRSIG_SIGNER_NAME = 18;

    uint constant DNSKEY_FLAGS = 0;
    uint constant DNSKEY_PROTOCOL = 2;
    uint constant DNSKEY_ALGORITHM = 3;
    uint constant DNSKEY_PUBKEY = 4;

    uint constant DNSKEY_FLAG_ZONEKEY = 0x100;

    uint constant NSEC3_HASH_ALGORITHM = 0;
    uint constant NSEC3_FLAGS = 1;
    uint constant NSEC3_ITERATIONS = 2;
    uint constant NSEC3_SALT_LENGTH = 4;
    uint constant NSEC3_SALT = 5;

    uint8 constant ALGORITHM_RSASHA256 = 8;

    uint8 constant DIGEST_ALGORITHM_SHA256 = 2;

    struct RRSet {
        uint32 inception;
        uint64 inserted;
        bytes20 hash;
    }

    // (name, type) => RRSet
    mapping (bytes32 => mapping(uint16 => RRSet)) rrsets;

    bytes public anchors;

    mapping (uint8 => Algorithm) public algorithms;
    mapping (uint8 => Digest) public digests;
    mapping (uint8 => NSEC3Digest) public nsec3Digests;

    event AlgorithmUpdated(uint8 id, address addr);
    event DigestUpdated(uint8 id, address addr);
    event NSEC3DigestUpdated(uint8 id, address addr);
    event RRSetUpdated(bytes name, bytes rrset);

    /**
     * @dev Constructor.
     * @param _anchors The binary format RR entries for the root DS records.
     */
    constructor(bytes _anchors) public {
        // Insert the 'trust anchors' - the key hashes that start the chain
        // of trust for all other records.
        anchors = _anchors;
        rrsets[keccak256(" ")][DNSTYPE_DS] = RRSet({
            inception: uint32(0),
            inserted: uint64(now),
            hash: bytes20(keccak256(anchors))
        });
        emit RRSetUpdated(" ", anchors);
    }

    /**
     * @dev Sets the contract address for a signature verification algorithm.
     *      Callable only by the owner.
     * @param id The algorithm ID
     * @param algo The address of the algorithm contract.
     */
    function setAlgorithm(uint8 id, Algorithm algo) public owner_only {
        algorithms[id] = algo;
        emit AlgorithmUpdated(id, algo);
    }

    /**
     * @dev Sets the contract address for a digest verification algorithm.
     *      Callable only by the owner.
     * @param id The digest ID
     * @param digest The address of the digest contract.
     */
    function setDigest(uint8 id, Digest digest) public owner_only {
        digests[id] = digest;
        emit DigestUpdated(id, digest);
    }

    /**
     * @dev Sets the contract address for an NSEC3 digest algorithm.
     *      Callable only by the owner.
     * @param id The digest ID
     * @param digest The address of the digest contract.
     */
    function setNSEC3Digest(uint8 id, NSEC3Digest digest) public owner_only {
        nsec3Digests[id] = digest;
        emit NSEC3DigestUpdated(id, digest);
    }

    /**
     * @dev Submits a signed set of RRs to the oracle.
     *
     * RRSETs are only accepted if they are signed with a key that is already
     * trusted, or if they are self-signed, and the signing key is identified by
     * a DS record that is already trusted.
     *
     * @param input The signed RR set. This is in the format described in section
     *        5.3.2 of RFC4035: The RRDATA section from the RRSIG without the signature
     *        data, followed by a series of canonicalised RR records that the signature
     *        applies to.
     * @param sig The signature data from the RRSIG record.
     * @param proof The DNSKEY or DS to validate the signature against. Must Already
     *        have been submitted and proved previously.
     */
    function submitRRSet(bytes memory input, bytes memory sig, bytes memory proof)
        public
    {
        bytes memory name;
        bytes memory rrs;
        (name, rrs) = validateSignedSet(input, sig, proof);

        uint32 inception = input.readUint32(RRSIG_INCEPTION);
        uint16 typecovered = input.readUint16(RRSIG_TYPE);

        RRSet storage set = rrsets[keccak256(name)][typecovered];
        if (set.inserted > 0) {
            // To replace an existing rrset, the signature must be at least as new
            require(inception >= set.inception);
        }
        if (set.hash == keccak256(rrs)) {
            // Already inserted!
            return;
        }

        rrsets[keccak256(name)][typecovered] = RRSet({
            inception: inception,
            inserted: uint64(now),
            hash: bytes20(keccak256(rrs))
        });
        emit RRSetUpdated(name, rrs);
    }

    /**
     * @dev Deletes an RR from the oracle.
     *
     * @param deleteType The DNS record type to delete.
     * @param deleteName which you want to delete
     * @param nsec The signed NSEC RRset. This is in the format described in section
     *        5.3.2 of RFC4035: The RRDATA section from the RRSIG without the signature
     *        data, followed by a series of canonicalised RR records that the signature
     *        applies to.
     */
    function deleteRRSet(uint16 deleteType, bytes deleteName, bytes memory nsec, bytes memory sig, bytes memory proof) public {
        bytes memory nsecName;
        bytes memory rrs;
        (nsecName, rrs) = validateSignedSet(nsec, sig, proof);

        // Don't let someone use an old proof to delete a new name
        require(rrsets[keccak256(deleteName)][deleteType].inception <= nsec.readUint32(RRSIG_INCEPTION));

        for (RRUtils.RRIterator memory iter = rrs.iterateRRs(0); !iter.done(); iter.next()) {
            // We're dealing with three names here:
            //   - deleteName is the name the user wants us to delete
            //   - nsecName is the owner name of the NSEC record
            //   - nextName is the next name specified in the NSEC record
            //
            // And three cases:
            //   - deleteName equals nsecName, in which case we can delete the
            //     record if it's not in the type bitmap.
            //   - nextName comes after nsecName, in which case we can delete
            //     the record if deleteName comes between nextName and nsecName.
            //   - nextName comes before nsecName, in which case nextName is the
            //     zone apez, and deleteName must come after nsecName.

            if(iter.dnstype == DNSTYPE_NSEC) {
                checkNsecName(iter, nsecName, deleteName, deleteType);
            } else if(iter.dnstype == DNSTYPE_NSEC3) {
                checkNsec3Name(iter, nsecName, deleteName, deleteType);
            } else {
                revert("Unrecognised record type");
            }

            delete rrsets[keccak256(deleteName)][deleteType];
            return;
        }
        // This should never reach.
        revert();
    }

    function checkNsecName(RRUtils.RRIterator memory iter, bytes memory nsecName, bytes memory deleteName, uint16 deleteType) private pure {
        uint rdataOffset = iter.rdataOffset;
        uint nextNameLength = iter.data.nameLength(rdataOffset);
        uint rDataLength = iter.nextOffset - iter.rdataOffset;

        // We assume that there is always typed bitmap after the next domain name
        require(rDataLength > nextNameLength);

        int compareResult = deleteName.compareNames(nsecName);
        if(compareResult == 0) {
            // Name to delete is on the same label as the NSEC record
            require(!iter.data.checkTypeBitmap(rdataOffset + nextNameLength, deleteType));
        } else {
            // First check if the NSEC next name comes after the NSEC name.
            bytes memory nextName = iter.data.substring(rdataOffset,nextNameLength);
            if(nsecName.compareNames(nextName) < 0) {
                // deleteName must come between nsecName and nextName
                require(compareResult > 0 && deleteName.compareNames(nextName) < 0);
            } else {
                // deleteName must come after nsecName
                require(compareResult > 0);
            }
        }
    }

    event Log(string message, bytes data);
    event Log(string message, bytes32 data);

    function checkNsec3Name(RRUtils.RRIterator memory iter, bytes memory nsecName, bytes memory deleteName, uint16 deleteType) private view {
        uint16 iterations = iter.data.readUint16(iter.rdataOffset + NSEC3_ITERATIONS);
        uint8 saltLength = iter.data.readUint8(iter.rdataOffset + NSEC3_SALT_LENGTH);
        bytes memory salt = iter.data.substring(iter.rdataOffset + NSEC3_SALT, saltLength);
        bytes32 deleteNameHash = nsec3Digests[iter.data.readUint8(iter.rdataOffset)].hash(salt, deleteName, iterations);

        uint8 nextLength = iter.data.readUint8(iter.rdataOffset + NSEC3_SALT + saltLength);
        require(nextLength <= 32);
        bytes32 nextNameHash = iter.data.readBytesN(iter.rdataOffset + NSEC3_SALT + saltLength + 1, nextLength);

        bytes32 nsecNameHash = nsecName.base32HexDecodeWord(1, uint(nsecName.readUint8(0)));

        if(deleteNameHash == nsecNameHash) {
            // Name to delete is on the same label as the NSEC record
            require(!iter.data.checkTypeBitmap(iter.rdataOffset + NSEC3_SALT + saltLength + 1 + nextLength, deleteType));
        } else {
            // Check if the NSEC next name comes after the NSEC name.
            if(nextNameHash > nsecNameHash) {
                // deleteName must come between nsecName and nextName
                require(deleteNameHash > nsecNameHash && deleteNameHash < nextNameHash);
            } else {
                // deleteName must come after nsecName
                require(deleteNameHash > nsecNameHash);
            }
        }
    }

    /**
     * @dev Returns data about the RRs (if any) known to this oracle with the provided type and name.
     * @param dnstype The DNS record type to query.
     * @param name The name to query, in DNS label-sequence format.
     * @return inception The unix timestamp at which the signature for this RRSET was created.
     * @return inserted The unix timestamp at which this RRSET was inserted into the oracle.
     * @return hash The hash of the RRset that was inserted.
     */
    function rrdata(uint16 dnstype, bytes memory name) public view returns (uint32, uint64, bytes20) {
        RRSet storage result = rrsets[keccak256(name)][dnstype];
        return (result.inception, result.inserted, result.hash);
    }

    /**
     * @dev Submits a signed set of RRs to the oracle.
     *
     * RRSETs are only accepted if they are signed with a key that is already
     * trusted, or if they are self-signed, and the signing key is identified by
     * a DS record that is already trusted.
     *
     * @param input The signed RR set. This is in the format described in section
     *        5.3.2 of RFC4035: The RRDATA section from the RRSIG without the signature
     *        data, followed by a series of canonicalised RR records that the signature
     *        applies to.
     * @param sig The signature data from the RRSIG record.
     * @param proof The DNSKEY or DS to validate the signature against. Must Already
     *        have been submitted and proved previously.
     */
    function validateSignedSet(bytes memory input, bytes memory sig, bytes memory proof) internal view returns(bytes memory name, bytes memory rrs) {
        require(validProof(input.readName(RRSIG_SIGNER_NAME), proof));

        uint32 inception = input.readUint32(RRSIG_INCEPTION);
        uint32 expiration = input.readUint32(RRSIG_EXPIRATION);
        uint16 typecovered = input.readUint16(RRSIG_TYPE);
        uint8 labels = input.readUint8(RRSIG_LABELS);

        // Extract the RR data
        uint rrdataOffset = input.nameLength(RRSIG_SIGNER_NAME) + 18;
        rrs = input.substring(rrdataOffset, input.length - rrdataOffset);

        // Do some basic checks on the RRs and extract the name
        name = validateRRs(rrs, typecovered);
        checkNameLabels(name, labels);

        // Validate the signature
        verifySignature(name, input, sig, proof);

        // TODO: Check inception and expiration using mod2^32 math

        // o  The validator's notion of the current time MUST be less than or
        //    equal to the time listed in the RRSIG RR's Expiration field.
        require(expiration > now);

        // o  The validator's notion of the current time MUST be greater than or
        //    equal to the time listed in the RRSIG RR's Inception field.
        require(inception < now);
    }

    function validProof(bytes name, bytes memory proof) internal view returns(bool) {
        uint16 dnstype = proof.readUint16(proof.nameLength(0));
        return rrsets[keccak256(name)][dnstype].hash == bytes20(keccak256(proof));
    }

    /**
     * @dev Validates a set of RRs.
     * @param data The RR data.
     * @param typecovered The type covered by the RRSIG record.
     */
    function validateRRs(bytes memory data, uint16 typecovered) internal pure returns (bytes memory name) {
        // Iterate over all the RRs
        for (RRUtils.RRIterator memory iter = data.iterateRRs(0); !iter.done(); iter.next()) {
            // We only support class IN (Internet)
            require(iter.class == DNSCLASS_IN);

            if(name.length == 0) {
                name = iter.name();
            } else {
                // Name must be the same on all RRs
                require(name.length == data.nameLength(iter.offset));
                require(name.equals(0, data, iter.offset, name.length));
            }

            // o  The RRSIG RR's Type Covered field MUST equal the RRset's type.
            require(iter.dnstype == typecovered);
        }
    }

    function checkNameLabels(bytes memory name, uint8 labels) internal pure {
        uint nameLabels = name.labelCount(0);
        // The name must either have the specified number of labels, or have a
        // "*.".
        require(nameLabels == labels || (nameLabels == labels + 1 && name.readUint16(0) == 0x012A));
    }

    /**
     * @dev Performs signature verification.
     *
     * Throws or reverts if unable to verify the record.
     *
     * @param name The name of the RRSIG record, in DNS label-sequence format.
     * @param data The original data to verify.
     * @param sig The signature data.
     */
    function verifySignature(bytes name, bytes memory data, bytes memory sig, bytes memory proof) internal view {
        uint signerNameLength = data.nameLength(RRSIG_SIGNER_NAME);

        // o  The RRSIG RR's Signer's Name field MUST be the name of the zone
        //    that contains the RRset.
        require(signerNameLength <= name.length);
        require(data.equals(RRSIG_SIGNER_NAME, name, name.length - signerNameLength, signerNameLength));

        // Set the return offset to point at the first RR
        uint offset = 18 + signerNameLength;

        // Check the proof
        uint16 dnstype = proof.readUint16(proof.nameLength(0));
        if (dnstype == DNSTYPE_DS) {
            require(verifyWithDS(data, sig, offset, proof));
        } else if (dnstype == DNSTYPE_DNSKEY) {
            require(verifyWithKnownKey(data, sig, proof));
        } else {
            revert("Unsupported proof record type");
        }
    }

    /**
     * @dev Attempts to verify a signed RRSET against an already known public key.
     * @param data The original data to verify.
     * @param sig The signature data.
     * @return True if the RRSET could be verified, false otherwise.
     */
    function verifyWithKnownKey(bytes memory data, bytes memory sig, bytes memory proof) internal view returns(bool) {
        uint signerNameLength = data.nameLength(RRSIG_SIGNER_NAME);

        // Extract algorithm and keytag
        uint8 algorithm = data.readUint8(RRSIG_ALGORITHM);
        uint16 keytag = data.readUint16(RRSIG_KEY_TAG);

        for (RRUtils.RRIterator memory iter = proof.iterateRRs(0); !iter.done(); iter.next()) {
            // Check the DNSKEY's owner name matches the signer name on the RRSIG
            require(proof.nameLength(0) == signerNameLength);
            require(proof.equals(0, data, RRSIG_SIGNER_NAME, signerNameLength));
            if (verifySignatureWithKey(iter.rdata(), algorithm, keytag, data, sig)) {
                return true;
            }
        }

        return false;
    }

    /**
     * @dev Attempts to verify a signed RRSET against an already known public key.
     * @param data The original data to verify.
     * @param sig The signature data.
     * @param offset The offset from the start of the data to the first RR.
     * @return True if the RRSET could be verified, false otherwise.
     */
    function verifyWithDS(bytes memory data, bytes memory sig, uint offset, bytes memory proof) internal view returns(bool) {
        // Extract algorithm and keytag
        uint8 algorithm = data.readUint8(RRSIG_ALGORITHM);
        uint16 keytag = data.readUint16(RRSIG_KEY_TAG);

        // Perhaps it's self-signed and verified by a DS record?
        for (RRUtils.RRIterator memory iter = data.iterateRRs(offset); !iter.done(); iter.next()) {
            if (iter.dnstype != DNSTYPE_DNSKEY) {
                return false;
            }

            bytes memory keyrdata = iter.rdata();
            if (verifySignatureWithKey(keyrdata, algorithm, keytag, data, sig)) {
                // It's self-signed - look for a DS record to verify it.
                if (verifyKeyWithDS(iter.name(), keyrdata, keytag, algorithm, proof)) {
                    return true;
                }
                // If we found a valid signature but no valid DS, no use checking other records too.
                return false;
            }
        }

        return false;
    }

    /**
     * @dev Attempts to verify some data using a provided key and a signature.
     * @param keyrdata The RDATA section of the key to use.
     * @param algorithm The algorithm ID of the key and signature.
     * @param keytag The keytag from the signature.
     * @param data The data to verify.
     * @param sig The signature to use.
     * @return True iff the key verifies the signature.
     */
    function verifySignatureWithKey(bytes memory keyrdata, uint8 algorithm, uint16 keytag, bytes data, bytes sig) internal view returns (bool) {
        if (algorithms[algorithm] == address(0)) {
            return false;
        }
        // TODO: Check key isn't expired, unless updating key itself

        // o The RRSIG RR's Signer's Name, Algorithm, and Key Tag fields MUST
        //   match the owner name, algorithm, and key tag for some DNSKEY RR in
        //   the zone's apex DNSKEY RRset.
        if (keyrdata.readUint8(DNSKEY_PROTOCOL) != 3) {
            return false;
        }
        if (keyrdata.readUint8(DNSKEY_ALGORITHM) != algorithm) {
            return false;
        }
        uint16 computedkeytag = computeKeytag(keyrdata);
        if (computedkeytag != keytag) {
            return false;
        }

        // o The matching DNSKEY RR MUST be present in the zone's apex DNSKEY
        //   RRset, and MUST have the Zone Flag bit (DNSKEY RDATA Flag bit 7)
        //   set.
        if (keyrdata.readUint16(DNSKEY_FLAGS) & DNSKEY_FLAG_ZONEKEY == 0) {
            return false;
        }

        return algorithms[algorithm].verify(keyrdata, data, sig);
    }

    /**
     * @dev Attempts to verify a key using DS records.
     * @param keyname The DNS name of the key, in DNS label-sequence format.
     * @param keyrdata The RDATA section of the key.
     * @param keytag The keytag of the key.
     * @param algorithm The algorithm ID of the key.
     * @return True if a DS record verifies this key.
     */
    function verifyKeyWithDS(bytes memory keyname, bytes memory keyrdata, uint16 keytag, uint8 algorithm, bytes memory data)
        internal view returns (bool)
    {
        for (RRUtils.RRIterator memory iter = data.iterateRRs(0); !iter.done(); iter.next()) {
            if (data.readUint16(iter.rdataOffset + DS_KEY_TAG) != keytag) {
                continue;
            }
            if (data.readUint8(iter.rdataOffset + DS_ALGORITHM) != algorithm) {
                continue;
            }

            uint8 digesttype = data.readUint8(iter.rdataOffset + DS_DIGEST_TYPE);
            Buffer.buffer memory buf;
            buf.init(keyname.length + keyrdata.length);
            buf.append(keyname);
            buf.append(keyrdata);
            if (verifyDSHash(digesttype, buf.buf, data.substring(iter.rdataOffset, iter.nextOffset - iter.rdataOffset))) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Attempts to verify a DS record's hash value against some data.
     * @param digesttype The digest ID from the DS record.
     * @param data The data to digest.
     * @param digest The digest data to check against.
     * @return True iff the digest matches.
     */
    function verifyDSHash(uint8 digesttype, bytes data, bytes digest) internal view returns (bool) {
        if (digests[digesttype] == address(0)) {
            return false;
        }
        return digests[digesttype].verify(data, digest.substring(4, digest.length - 4));
    }

    /**
     * @dev Computes the keytag for a chunk of data.
     * @param data The data to compute a keytag for.
     * @return The computed key tag.
     */
    function computeKeytag(bytes memory data) internal pure returns (uint16) {
        uint ac;
        for (uint i = 0; i < data.length; i += 2) {
            ac += data.readUint16(i);
        }
        ac += (ac >> 16) & 0xFFFF;
        return uint16(ac & 0xFFFF);
    }
}
