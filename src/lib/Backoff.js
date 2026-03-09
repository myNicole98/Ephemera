.pragma library

// Exponential backoff with full jitter for error cooldown.
// Replaces the flat 2-second cooldown with progressive delays that spread
// retries and avoid thundering-herd synchronization.

/**
 * Compute the next backoff delay using exponential backoff with full jitter.
 *
 * Formula: delay = random(floor, min(maxDelayMs, baseDelayMs * 2^attempt))
 * where floor = baseDelayMs * 0.5 ensures a minimum wait even at low jitter.
 *
 * @param {number} attempt - Zero-based attempt counter (0 = first error).
 * @param {number} [baseDelayMs=2000] - Base delay in milliseconds.
 * @param {number} [maxDelayMs=30000] - Maximum delay cap in milliseconds.
 * @returns {number} Delay in milliseconds (always >= baseDelayMs * 0.5).
 */
function computeDelay(attempt, baseDelayMs, maxDelayMs) {
    var base = baseDelayMs || 2000;
    var max = maxDelayMs || 30000;
    var exp = Math.min(max, base * Math.pow(2, attempt || 0));
    var floor = base * 0.5;
    return floor + Math.random() * (exp - floor);
}

/**
 * Determine whether a retry is still in the cooldown period.
 *
 * @param {number} lastErrorTime - Timestamp (ms) of the last error, 0 if no error.
 * @param {number} consecutiveErrors - Number of consecutive errors so far.
 * @param {number} [baseDelayMs=2000] - Base delay for backoff calculation.
 * @param {number} [maxDelayMs=30000] - Maximum delay cap.
 * @returns {boolean} true if the cooldown period has NOT elapsed and retry should be blocked.
 */
function isInCooldown(lastErrorTime, consecutiveErrors, baseDelayMs, maxDelayMs) {
    if (lastErrorTime <= 0 || consecutiveErrors <= 0) return false;
    var delay = computeDelay(consecutiveErrors - 1, baseDelayMs, maxDelayMs);
    return (Date.now() - lastErrorTime) < delay;
}

/**
 * Get the deterministic (non-jittered) upper bound of the cooldown for a given error count.
 *
 * Useful for UI display since the actual jittered delay varies per call.
 *
 * @param {number} consecutiveErrors - Number of consecutive errors so far.
 * @param {number} [baseDelayMs=2000] - Base delay.
 * @param {number} [maxDelayMs=30000] - Maximum delay cap.
 * @returns {number} Upper bound delay in milliseconds.
 */
function maxDelayForAttempt(consecutiveErrors, baseDelayMs, maxDelayMs) {
    if (consecutiveErrors <= 0) return 0;
    var base = baseDelayMs || 2000;
    var max = maxDelayMs || 30000;
    return Math.min(max, base * Math.pow(2, consecutiveErrors - 1));
}
