module minter::token_minter {
    use aptos_framework::object::{Self, ConstructorRef, Object};
    use aptos_token_objects::collection::{Self, Collection};
    use aptos_token_objects::property_map;
    use aptos_token_objects::royalty::{Self, Royalty};
    use aptos_token_objects::token::{Self, Token};
    use minter::apt_payment;
    use minter::collection_helper;
    use minter::collection_properties_old;
    use minter::collection_refs_old;
    use minter::token_helper_old;
    use minter::whitelist;
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_framework::event;
    use minter::token_refs_old;

    /// Current version of the token minter
    const VERSION: u64 = 1;

    /// Not the owner of the object
    const ENOT_OBJECT_OWNER: u64 = 1;
    /// The token minter does not exist
    const ETOKEN_MINTER_DOES_NOT_EXIST: u64 = 2;
    /// The collection does not exist
    const ECOLLECTION_DOES_NOT_EXIST: u64 = 3;
    /// The token minter is paused
    const ETOKEN_MINTER_IS_PAUSED: u64 = 4;
    /// The token does not exist
    const ETOKEN_DOES_NOT_EXIST: u64 = 5;
    /// The provided signer is not the creator
    const ENOT_CREATOR: u64 = 6;
    /// The field being changed is not mutable
    const EFIELD_NOT_MUTABLE: u64 = 7;
    /// The token being burned is not burnable
    const ETOKEN_NOT_BURNABLE: u64 = 8;
    /// The property map being mutated is not mutable
    const EPROPERTIES_NOT_MUTABLE: u64 = 9;
    /// Not the creator of the object
    const ENOT_OBJECT_CREATOR: u64 = 10;
    /// The caller does not own the token
    const ENOT_TOKEN_OWNER: u64 = 11;
    /// The token does not support forced transfers
    const ETOKEN_NOT_TRANSFERABLE: u64 = 12;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct TokenMinter has key {
        /// Version of the token minter
        version: u64,
        /// The collection that the token minter will mint from.
        collection: Object<Collection>,
        /// Whether the token minter is paused.
        paused: bool,
        /// Whether only the creator can mint tokens.
        creator_mint_only: bool,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct TokenMinterRefs has key {
        /// Used to generate signer, needed for adding additional extensions and minting tokens.
        extend_ref: object::ExtendRef,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct TokenRefs has key {
        /// Used to generate signer for the token. Can be used for extending the
        /// token or transferring out objects from the token
        extend_ref: object::ExtendRef,
        /// Used to burn.
        burn_ref: Option<token::BurnRef>,
        /// Used to control freeze.
        transfer_ref: Option<object::TransferRef>,
        /// Used to mutate fields
        mutator_ref: Option<token::MutatorRef>,
        /// Used to mutate properties
        property_mutator_ref: property_map::MutatorRef,
    }

    #[event]
    /// Event emitted when the TokenMinter is initialized.
    struct InitTokenMinter has drop, store {
        token_minter: Object<TokenMinter>,
        collection: Object<Collection>,
        paused: bool,
        creator_mint_only: bool,
    }

    public entry fun init_token_minter(
        creator: &signer,
        description: String,
        max_supply: Option<u64>, // If value is present, collection configured to have a fixed supply.
        name: String,
        uri: String,
        mutable_description: bool,
        mutable_royalty: bool,
        mutable_uri: bool,
        mutable_token_description: bool,
        mutable_token_name: bool,
        mutable_token_properties: bool,
        mutable_token_uri: bool,
        tokens_burnable_by_creator: bool,
        tokens_transferable_by_creator: bool,
        royalty: Option<Royalty>,
        creator_mint_only: bool,
        soulbound: bool,
    ) {
        init_token_minter_object(
            creator, description, max_supply, name, uri, mutable_description, mutable_royalty, mutable_uri,
            mutable_token_description, mutable_token_name, mutable_token_properties, mutable_token_uri,
            tokens_burnable_by_creator, tokens_transferable_by_creator, royalty, creator_mint_only, soulbound
        );
    }

    /// Creates a new collection and token minter, these will each be contained in separate objects.
    /// The collection object will contain the `Collection`, `CollectionRefs`, CollectionProperties`.
    /// The token minter object will contain the `TokenMinter` and `TokenMinterProperties`.
    public fun init_token_minter_object(
        creator: &signer,
        description: String,
        max_supply: Option<u64>, // If value is present, collection configured to have a fixed supply.
        name: String,
        uri: String,
        mutable_description: bool,
        mutable_royalty: bool,
        mutable_uri: bool,
        mutable_token_description: bool,
        mutable_token_name: bool,
        mutable_token_properties: bool,
        mutable_token_uri: bool,
        tokens_burnable_by_creator: bool,
        tokens_transferable_by_creator: bool,
        royalty: Option<Royalty>,
        creator_mint_only: bool,
        soulbound: bool,
    ): Object<TokenMinter> {
        let creator_address = signer::address_of(creator);
        let (constructor_ref, object_signer) = create_object(creator_address);
        let collection_constructor_ref = &collection_helper::create_collection(
            &object_signer,
            description,
            max_supply,
            name,
            royalty,
            uri,
        );

        let collection_signer = collection_refs_old::create_refs(
            collection_constructor_ref,
            mutable_description,
            mutable_uri,
            mutable_royalty,
        );

        collection_properties_old::create_properties(
            &collection_signer,
            mutable_description,
            mutable_uri,
            mutable_token_description,
            mutable_token_name,
            mutable_token_properties,
            mutable_token_uri,
            tokens_burnable_by_creator,
            tokens_transferable_by_creator,
            soulbound,
        );

        init_token_minter_object_internal(
            &object_signer,
            &constructor_ref,
            object::object_from_constructor_ref(collection_constructor_ref),
            creator_mint_only,
        )
    }

    public entry fun mint_tokens(
        minter: &signer,
        token_minter_object: Object<TokenMinter>,
        name: String,
        description: String,
        uri: String,
        amount: u64,
        property_keys: vector<vector<String>>,
        property_types: vector<vector<String>>,
        property_values: vector<vector<vector<u8>>>,
        recipient_addrs: vector<address>,
    ) acquires TokenMinter, TokenMinterRefs {
        mint_tokens_object(
            minter, token_minter_object, name, description, uri, amount, property_keys, property_types, property_values, recipient_addrs
        );
    }

    /// Anyone can mint if they meet all extension conditions.
    /// @param minter The signer that is minting the tokens.
    /// @param token_minter_object The TokenMinter object (references the collection)
    /// @param name The name of the token.
    /// @param description The description of the token.
    /// @param uri The URI of the token.
    /// @param amount The amount of tokens to mint.
    /// @param property_keys The keys of the properties.
    /// @param property_types The types of the properties.
    /// @param property_values The values of the properties.
    /// @param recipient_addrs The addresses to mint the tokens to.
    public fun mint_tokens_object(
        minter: &signer,
        token_minter_object: Object<TokenMinter>,
        name: String,
        description: String,
        uri: String,
        amount: u64,
        property_keys: vector<vector<String>>,
        property_types: vector<vector<String>>,
        property_values: vector<vector<vector<u8>>>,
        recipient_addrs: vector<address>,
    ): vector<Object<Token>> acquires TokenMinter, TokenMinterRefs {
        token_helper_old::validate_token_properties(amount, &property_keys, &property_types, &property_values, &recipient_addrs);

        let token_minter = borrow_mut(token_minter_object);
        assert!(!token_minter.paused, error::invalid_state(ETOKEN_MINTER_IS_PAUSED));

        if (token_minter.creator_mint_only) {
            assert_token_minter_creator(signer::address_of(minter), token_minter_object);
        };

        // Must check ALL extensions first before minting
        check_and_execute_extensions(minter, token_minter_object, amount);

        let tokens = vector[];
        let i = 0;
        let token_minter_signer = &token_minter_signer_internal(token_minter_object);
        while (i < amount) {
            // TODO: When the collection is soulbound, we should enforce that
            // the recipient_addr is the same as the minter's address unless the
            // minter is the Object<TokenMinter> owner
            let token = mint_internal(
                token_minter_signer,
                token_minter.collection,
                description,
                name,
                uri,
                *vector::borrow(&property_keys, i),
                *vector::borrow(&property_types, i),
                *vector::borrow(&property_values, i),
                *vector::borrow(&recipient_addrs, i),
            );
            vector::push_back(&mut tokens, token);
            i = i + 1;
        };

        tokens
    }

    /// This function checks all extensions the `token_minter` has and executes them if they are enabled.
    /// This function reverts if any of the extensions fail.
    fun check_and_execute_extensions(minter: &signer, token_minter: Object<TokenMinter>, amount: u64) {
        let minter_address = signer::address_of(minter);

        if (whitelist::is_whitelist_enabled(token_minter)) {
            whitelist::execute(token_minter, amount, minter_address);
        };
        if (apt_payment::is_apt_payment_enabled(token_minter)) {
            apt_payment::execute(minter, token_minter, amount);
        };
    }

    fun init_token_minter_object_internal(
        object_signer: &signer,
        constructor_ref: &ConstructorRef,
        collection: Object<Collection>,
        creator_mint_only: bool,
    ): Object<TokenMinter> {
        let paused = false;
        move_to(object_signer, TokenMinter {
            version: VERSION,
            collection,
            paused,
            creator_mint_only,
        });
        move_to(object_signer, TokenMinterRefs { extend_ref: object::generate_extend_ref(constructor_ref) });

        let token_minter = object::object_from_constructor_ref(constructor_ref);
        event::emit(InitTokenMinter { token_minter, collection, paused, creator_mint_only });

        token_minter
    }

    fun mint_internal(
        token_minter_signer: &signer,
        collection: Object<Collection>,
        description: String,
        name: String,
        uri: String,
        property_keys: vector<String>,
        property_types: vector<String>,
        property_values: vector<vector<u8>>,
        recipient_addr: address,
    ): Object<Token> {
        let token_constructor_ref = &token::create(
            token_minter_signer,
            collection::name(collection),
            description,
            name,
            royalty::get(collection),
            uri
        );

        let properties = property_map::prepare_input(property_keys, property_types, property_values);
        property_map::init(token_constructor_ref, properties);

        create_token_refs_and_transfer(
            token_minter_signer,
            collection,
            token_constructor_ref,
            recipient_addr,
        )
    }

    fun create_token_refs_and_transfer<T: key>(
        token_minter_signer: &signer,
        collection: Object<T>,
        token_constructor_ref: &ConstructorRef,
        recipient_addr: address,
    ): Object<Token> {
        token_refs_old::create_refs(token_constructor_ref, collection);

        token_helper_old::transfer_token(
            token_minter_signer,
            recipient_addr,
            collection_properties_old::soulbound(collection),
            token_constructor_ref,
        )
    }

    // ================================= extensions ================================= //

    public entry fun add_or_update_whitelist(
        creator: &signer,
        token_minter: Object<TokenMinter>,
        whitelisted_addresses: vector<address>,
        max_mint_per_whitelists: vector<u64>,
    ) acquires TokenMinterRefs {
        assert_token_minter_creator(signer::address_of(creator), token_minter);

        whitelist::add_or_update_whitelist(
            &token_minter_signer_internal(token_minter),
            token_minter,
            whitelisted_addresses,
            max_mint_per_whitelists
        );
    }

    public entry fun remove_whitelist_extension(creator: &signer, token_minter: Object<TokenMinter>) {
        assert_token_minter_creator(signer::address_of(creator), token_minter);
        whitelist::remove_whitelist(token_minter);
    }

    public entry fun add_or_update_apt_payment_extension(
        creator: &signer,
        token_minter: Object<TokenMinter>,
        amount: u64,
        destination: address,
    ) acquires TokenMinterRefs {
        assert_token_minter_creator(signer::address_of(creator), token_minter);
        apt_payment::add_or_update_apt_payment(&token_minter_signer_internal(token_minter), token_minter, amount, destination);
    }

    public entry fun remove_apt_payment_extension(
        creator: &signer,
        token_minter: Object<TokenMinter>
    ) {
        assert_token_minter_creator(signer::address_of(creator), token_minter);
        apt_payment::remove_apt_payment(token_minter);
    }

    // ================================= TokenMinter Mutators ================================= //

    public entry fun set_version(
        creator: &signer,
        token_minter: Object<TokenMinter>,
        version: u64,
    ) acquires TokenMinter {
        assert_token_minter_creator(signer::address_of(creator), token_minter);
        let token_minter = borrow_mut(token_minter);
        token_minter.version = version;
    }

    public entry fun set_paused(
        creator: &signer,
        token_minter: Object<TokenMinter>,
        paused: bool,
    ) acquires TokenMinter {
        assert_token_minter_creator(signer::address_of(creator), token_minter);
        let token_minter = borrow_mut(token_minter);
        token_minter.paused = paused;
    }

    public entry fun set_creator_mint_only(
        creator: &signer,
        token_minter: Object<TokenMinter>,
        creator_mint_only: bool,
    ) acquires TokenMinter {
        assert_token_minter_creator(signer::address_of(creator), token_minter);
        let token_minter = borrow_mut(token_minter);
        token_minter.creator_mint_only = creator_mint_only;
    }

    /// Destroys the token minter, this is done after the collection has been fully minted.
    /// Assert that only the creator can call this function.
    /// Assert that the creator owns the collection.
    public entry fun destroy_token_minter(
        creator: &signer,
        token_minter_object: Object<TokenMinter>,
    ) acquires TokenMinter {
        let creator_address = signer::address_of(creator);
        assert_token_minter_creator(creator_address, token_minter_object);

        let TokenMinter {
            version: _,
            collection: _,
            paused: _,
            creator_mint_only: _,
        } = move_from<TokenMinter>(object::object_address(&token_minter_object));
    }

    // ================================= View Functions ================================= //

    fun token_minter_signer_internal(token_minter: Object<TokenMinter>): signer acquires TokenMinterRefs {
        let extend_ref = &borrow_refs(&token_minter).extend_ref;
        object::generate_signer_for_extending(extend_ref)
    }

    fun create_object(creator_address: address): (ConstructorRef, signer) {
        let constructor_ref = object::create_object(creator_address);
        let object_signer = object::generate_signer(&constructor_ref);
        (constructor_ref, object_signer)
    }

    fun token_minter_address<T: key>(token_minter: &Object<T>): address {
        let token_minter_address = object::object_address(token_minter);
        assert!(exists<TokenMinter>(token_minter_address), error::not_found(ETOKEN_MINTER_DOES_NOT_EXIST));
        token_minter_address
    }

    fun assert_token_minter_creator(creator_addr: address, token_minter: Object<TokenMinter>) {
        assert!(object::owns(token_minter, creator_addr), error::invalid_argument(ENOT_CREATOR));
    }

    fun assert_owner<T: key>(owner: address, object: Object<T>) {
        assert!(object::owner(object) == owner, error::invalid_argument(ENOT_OBJECT_OWNER));
    }

    inline fun borrow<T: key>(token_minter: Object<T>): &TokenMinter acquires TokenMinter {
        borrow_global<TokenMinter>(token_minter_address(&token_minter))
    }

    inline fun borrow_mut<T: key>(token_minter: Object<T>): &mut TokenMinter acquires TokenMinter {
        borrow_global_mut<TokenMinter>(token_minter_address(&token_minter))
    }

    inline fun borrow_refs(token_minter: &Object<TokenMinter>): &TokenMinterRefs acquires TokenMinterRefs {
        borrow_global<TokenMinterRefs>(token_minter_address(token_minter))
    }

    #[view]
    public fun token_minter_signer(creator: &signer, token_minter: Object<TokenMinter>): signer acquires TokenMinterRefs {
        let creator_address = signer::address_of(creator);
        assert_owner(creator_address, token_minter);
        let extend_ref = &borrow_refs(&token_minter).extend_ref;
        object::generate_signer_for_extending(extend_ref)
    }

    #[view]
    public fun version(token_minter: Object<TokenMinter>): u64 acquires TokenMinter {
        borrow(token_minter).version
    }

    #[view]
    public fun collection(token_minter: Object<TokenMinter>): Object<Collection> acquires TokenMinter {
        borrow(token_minter).collection
    }

    #[view]
    public fun creator(token_minter: Object<TokenMinter>): address {
        object::owner(token_minter)
    }

    #[view]
    public fun paused(token_minter: Object<TokenMinter>): bool acquires TokenMinter {
        borrow(token_minter).paused
    }

    #[view]
    public fun tokens_minted(token_minter: Object<TokenMinter>): u64 acquires TokenMinter {
        let collection_obj = borrow(token_minter).collection;
        // Borrow here is OK because we always track supply
        *option::borrow(&collection::count(collection_obj))
    }

    #[view]
    public fun creator_mint_only(token_minter: Object<TokenMinter>): bool acquires TokenMinter {
        borrow(token_minter).creator_mint_only
    }
}