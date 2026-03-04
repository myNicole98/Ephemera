.pragma library

// Pure-function variant store operations.
// The store is a plain JS object: { msgId: [ {content, thinking, modelName}, ... ] }

// Save a variant into the store, enforcing a max cap with FIFO eviction.
// Returns { store, evicted, newVariantIndex } where evicted is the count of evicted entries.
function saveVariant(store, msgId, index, content, thinking, modelName, maxVariants) {
    if (!store[msgId]) store[msgId] = [];
    store[msgId][index] = {
        content: content || "",
        thinking: thinking || "",
        modelName: modelName || ""
    };

    var evicted = 0;
    while (store[msgId].length > maxVariants) {
        store[msgId].shift();
        evicted++;
    }

    return { store: store, evicted: evicted };
}

// Get a variant from the store. Returns the variant object or null.
function getVariant(store, msgId, index) {
    if (!store[msgId] || index >= store[msgId].length || !store[msgId][index])
        return null;
    return store[msgId][index];
}

// Remove all variants for a given message ID.
function removeVariants(store, msgId) {
    delete store[msgId];
    return store;
}

// Adjust variant indices after eviction.
// Returns { variantIndex, variantCount } for the message model.
function adjustAfterEviction(evicted, currentVariantIndex, storeLength, isStreamingThisMsg) {
    var newIndex = Math.max(0, Math.min(currentVariantIndex - evicted, storeLength - 1));
    var logicalCount = isStreamingThisMsg ? storeLength + 1 : storeLength;
    return { variantIndex: newIndex, variantCount: logicalCount };
}
