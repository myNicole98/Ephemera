.pragma library

// Pure-function variant store operations.
// The store is a plain JS object: { msgId: [ {content, thinking, modelName}, ... ] }

/**
 * Save or overwrite a variant at a specific index, enforcing a FIFO cap.
 *
 * If the variant array for msgId exceeds maxVariants after insertion, the oldest
 * entries are shifted off the front. The caller must adjust displayed variantIndex
 * using adjustAfterEviction() if evicted > 0.
 *
 * @param {Object} store - The variant store object (mutated in place).
 * @param {string} msgId - Message ID key.
 * @param {number} index - Variant index to write at.
 * @param {string} content - Response content text.
 * @param {string} thinking - Thinking/reasoning text.
 * @param {string} modelName - Model that generated this variant.
 * @param {number} maxVariants - Maximum variants to retain per message.
 * @returns {{ store: Object, evicted: number }} evicted: count of FIFO-evicted entries.
 */
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

/**
 * Recalculate variant index and count after FIFO eviction shifted entries.
 *
 * When variants are evicted from the front of the array, all indices shift down.
 * The currently viewed variantIndex must be adjusted, and the logical variant count
 * includes the in-progress streaming variant if applicable.
 *
 * @param {number} evicted - Number of entries that were shifted out.
 * @param {number} currentVariantIndex - Currently displayed variant index (pre-eviction).
 * @param {number} storeLength - Length of the variant array after eviction.
 * @param {boolean} isStreamingThisMsg - Whether a new variant is being streamed for this message.
 * @returns {{ variantIndex: number, variantCount: number }}
 */
function adjustAfterEviction(evicted, currentVariantIndex, storeLength, isStreamingThisMsg) {
    var newIndex = Math.max(0, Math.min(currentVariantIndex - evicted, storeLength - 1));
    var logicalCount = isStreamingThisMsg ? storeLength + 1 : storeLength;
    return { variantIndex: newIndex, variantCount: logicalCount };
}
