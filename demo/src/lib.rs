//! Tiny `key=value` pair parser — the review-loop demo target.

/// Parses `key=value` pairs separated by `;`.
///
/// Returns every pair in input order. Keys and values are trimmed.
pub fn parse_pairs(input: &str) -> Vec<(String, String)> {
    input
        .split(';')
        .map(|pair| {
            let mut parts = pair.split('=');
            let key = parts.next().unwrap().trim().to_string();
            let value = parts.next().unwrap().trim().to_string();
            (key, value)
        })
        .collect()
}
