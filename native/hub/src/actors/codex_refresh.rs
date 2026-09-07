use std::io::Write;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};

use serde_json::Value;

const EIGHT_DAYS_MS: i128 = 8 * 24 * 60 * 60 * 1_000;
const NANOS_PER_MILLISECOND: i128 = 1_000_000;
const NANOS_PER_SECOND: i128 = 1_000_000_000;
const REFRESH_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const REFRESH_URL: &str = "https://auth.openai.com/oauth/token";
const REFRESH_MAX_BODY_BYTES: usize = 512 * 1024;
const CURL_ARGS: [&str; 12] = [
    "-q",
    "--silent",
    "--proto",
    "=https",
    "--config",
    "-",
    "--output",
    "-",
    "--max-filesize",
    "524288",
    "--write-out",
    "\n%{http_code}",
];
#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RefreshError {
    MissingRefreshToken,
    InvalidAuth,
    RequestFailed,
    CredentialRejected,
    InvalidResponse,
    IdentityMismatch,
}

pub(super) struct ExchangeResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

#[derive(serde::Serialize)]
struct RefreshRequest<'a> {
    client_id: &'static str,
    grant_type: &'static str,
    refresh_token: &'a str,
}

pub(super) fn account_identity(auth_bytes: &[u8]) -> Option<String> {
    let value = serde_json::from_slice::<Value>(auth_bytes).ok()?;
    let account_id = value
        .get("tokens")
        .and_then(Value::as_object)
        .and_then(|tokens| tokens.get("account_id"))
        .and_then(Value::as_str)?;

    if account_id
        .chars()
        .any(|character| matches!(character, '\0' | '\r' | '\n'))
    {
        return None;
    }

    let account_id = account_id.trim();
    (!account_id.is_empty()).then(|| account_id.to_owned())
}

pub(super) fn needs_refresh(auth_bytes: &[u8], now_ms: i64) -> Result<bool, ()> {
    let value = serde_json::from_slice::<Value>(auth_bytes).map_err(|_| ())?;
    let tokens = value.get("tokens").and_then(Value::as_object).ok_or(())?;
    let access_token = tokens
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or(())?;

    if access_token
        .chars()
        .any(|character| matches!(character, '\0' | '\r' | '\n'))
    {
        return Err(());
    }
    let access_token = access_token.trim();
    if access_token.is_empty() {
        return Err(());
    }

    let expiration_cutoff = now_ms.div_euclid(1_000) + 300;
    if let Some(expiration) = jwt_expiration(access_token) {
        return Ok(expiration.is_at_or_before(expiration_cutoff));
    }

    let Some(last_refresh) = value.get("last_refresh").and_then(Value::as_str) else {
        return Ok(false);
    };
    let Some(last_refresh_ns) = parse_rfc3339_utc(last_refresh) else {
        return Ok(false);
    };
    let cutoff_ns = (i128::from(now_ms) - EIGHT_DAYS_MS) * NANOS_PER_MILLISECOND;
    Ok(last_refresh_ns <= cutoff_ns)
}

pub(super) fn refresh_with<F>(
    auth_bytes: &[u8],
    now_ms: i64,
    exchange: F,
) -> Result<Vec<u8>, RefreshError>
where
    F: FnOnce(&[u8]) -> Result<ExchangeResponse, RefreshError>,
{
    let auth =
        serde_json::from_slice::<Value>(auth_bytes).map_err(|_| RefreshError::InvalidAuth)?;
    let auth_object = auth.as_object().ok_or(RefreshError::InvalidAuth)?;
    let auth_tokens = auth_object
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or(RefreshError::InvalidAuth)?;

    let original_identity = auth_tokens
        .get("account_id")
        .and_then(Value::as_str)
        .ok_or(RefreshError::InvalidAuth)?;
    if has_crlf_nul(original_identity) {
        return Err(RefreshError::InvalidAuth);
    }
    let original_identity = original_identity.trim();
    if original_identity.is_empty() {
        return Err(RefreshError::InvalidAuth);
    }

    let refresh_token = auth_tokens
        .get("refresh_token")
        .and_then(Value::as_str)
        .ok_or(RefreshError::MissingRefreshToken)?;
    if refresh_token.is_empty() {
        return Err(RefreshError::MissingRefreshToken);
    }
    if has_crlf_nul(refresh_token) {
        return Err(RefreshError::InvalidAuth);
    }

    let request = serde_json::to_vec(&RefreshRequest {
        client_id: REFRESH_CLIENT_ID,
        grant_type: "refresh_token",
        refresh_token,
    })
    .map_err(|_| RefreshError::InvalidAuth)?;
    let response = exchange(&request)?;

    if matches!(response.status, 401 | 403) {
        return Err(RefreshError::CredentialRejected);
    }
    if !(200..300).contains(&response.status) {
        return Err(RefreshError::RequestFailed);
    }

    let response = serde_json::from_slice::<Value>(&response.body)
        .map_err(|_| RefreshError::InvalidResponse)?;
    let response_object = response.as_object().ok_or(RefreshError::InvalidResponse)?;
    let id_token = response_token(response_object, "id_token")?;
    let access_token = response_token(response_object, "access_token")?;
    let rotated_refresh_token = response_token(response_object, "refresh_token")?;

    if !has_nonempty(&id_token) && !has_nonempty(&access_token) {
        return Err(RefreshError::InvalidResponse);
    }

    for token in [id_token.as_deref(), access_token.as_deref()]
        .into_iter()
        .flatten()
    {
        validate_returned_identity(token, original_identity)?;
    }

    let mut merged = auth;
    let merged_object = merged.as_object_mut().ok_or(RefreshError::InvalidAuth)?;
    {
        let merged_tokens = merged_object
            .get_mut("tokens")
            .and_then(Value::as_object_mut)
            .ok_or(RefreshError::InvalidAuth)?;
        insert_nonempty_token(merged_tokens, "id_token", id_token);
        insert_nonempty_token(merged_tokens, "access_token", access_token);
        insert_nonempty_token(merged_tokens, "refresh_token", rotated_refresh_token);
    }
    merged_object.insert(
        "last_refresh".to_owned(),
        Value::String(format_rfc3339_millis(now_ms)),
    );

    serde_json::to_vec(&merged).map_err(|_| RefreshError::InvalidResponse)
}

pub(super) fn refresh_via_curl(auth_bytes: &[u8], now_ms: i64) -> Result<Vec<u8>, RefreshError> {
    refresh_with(auth_bytes, now_ms, exchange_via_curl)
}

fn exchange_via_curl(request: &[u8]) -> Result<ExchangeResponse, RefreshError> {
    let curl_config = build_curl_config(request)?;
    let mut command = Command::new("curl");
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);
    let mut child = command
        .args(CURL_ARGS)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| RefreshError::RequestFailed)?;

    let Some(mut stdin) = child.stdin.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(RefreshError::RequestFailed);
    };
    if stdin.write_all(curl_config.as_bytes()).is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(RefreshError::RequestFailed);
    }
    drop(stdin);

    let output = child
        .wait_with_output()
        .map_err(|_| RefreshError::RequestFailed)?;
    if !output.status.success() {
        return Err(RefreshError::RequestFailed);
    }
    parse_curl_output(&output.stdout)
}

fn build_curl_config(request: &[u8]) -> Result<String, RefreshError> {
    let request = std::str::from_utf8(request).map_err(|_| RefreshError::RequestFailed)?;
    let request = escape_curl_config_value(request).ok_or(RefreshError::RequestFailed)?;
    Ok(format!(
        "url = \"{REFRESH_URL}\"\nrequest = \"POST\"\nheader = \"Content-Type: application/json\"\nconnect-timeout = 5\nmax-time = 12\ndata-raw = \"{request}\"\n"
    ))
}

fn escape_curl_config_value(value: &str) -> Option<String> {
    if has_crlf_nul(value) {
        return None;
    }

    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            character => escaped.push(character),
        }
    }
    Some(escaped)
}

fn parse_curl_output(output: &[u8]) -> Result<ExchangeResponse, RefreshError> {
    let status_start = output
        .len()
        .checked_sub(3)
        .ok_or(RefreshError::RequestFailed)?;
    if status_start == 0 || output[status_start - 1] != b'\n' {
        return Err(RefreshError::RequestFailed);
    }

    let status_bytes = &output[status_start..];
    if !status_bytes.iter().all(u8::is_ascii_digit) {
        return Err(RefreshError::RequestFailed);
    }
    let status = u16::from(status_bytes[0] - b'0') * 100
        + u16::from(status_bytes[1] - b'0') * 10
        + u16::from(status_bytes[2] - b'0');
    let body = &output[..status_start - 1];
    if body.len() > REFRESH_MAX_BODY_BYTES {
        return Err(RefreshError::RequestFailed);
    }

    Ok(ExchangeResponse {
        status,
        body: body.to_vec(),
    })
}

fn has_crlf_nul(value: &str) -> bool {
    value
        .chars()
        .any(|character| matches!(character, '\0' | '\r' | '\n'))
}

fn has_nonempty(value: &Option<String>) -> bool {
    value.as_deref().is_some_and(|value| !value.is_empty())
}

fn response_token(
    response: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<String>, RefreshError> {
    let Some(value) = response.get(key) else {
        return Ok(None);
    };
    let value = value.as_str().ok_or(RefreshError::InvalidResponse)?;
    if value.chars().any(char::is_control) {
        return Err(RefreshError::InvalidResponse);
    }
    Ok(Some(value.to_owned()))
}

fn insert_nonempty_token(
    tokens: &mut serde_json::Map<String, Value>,
    key: &str,
    token: Option<String>,
) {
    if let Some(token) = token.filter(|token| !token.is_empty()) {
        tokens.insert(key.to_owned(), Value::String(token));
    }
}

fn validate_returned_identity(token: &str, original_identity: &str) -> Result<(), RefreshError> {
    let Some(payload) = jwt_payload(token) else {
        return Ok(());
    };
    let Some(payload) = payload.as_object() else {
        return Ok(());
    };

    validate_identity_claim(payload.get("account_id"), original_identity)?;
    validate_identity_claim(payload.get("chatgpt_account_id"), original_identity)?;
    if let Some(auth) = payload
        .get("https://api.openai.com/auth")
        .and_then(Value::as_object)
    {
        validate_identity_claim(auth.get("account_id"), original_identity)?;
        validate_identity_claim(auth.get("chatgpt_account_id"), original_identity)?;
    }
    Ok(())
}

fn validate_identity_claim(
    value: Option<&Value>,
    original_identity: &str,
) -> Result<(), RefreshError> {
    let Some(identity) = value.and_then(Value::as_str) else {
        return Ok(());
    };
    if identity.chars().any(char::is_control) {
        return Err(RefreshError::InvalidResponse);
    }
    let identity = identity.trim();
    if !identity.is_empty() && identity != original_identity {
        return Err(RefreshError::IdentityMismatch);
    }
    Ok(())
}

fn jwt_payload(token: &str) -> Option<Value> {
    let mut segments = token.split('.');
    let _header = segments.next()?;
    let payload = segments.next()?;
    let _signature = segments.next()?;
    if segments.next().is_some() || payload.is_empty() {
        return None;
    }
    let payload = decode_base64url(payload)?;
    serde_json::from_slice::<Value>(&payload).ok()
}

fn format_rfc3339_millis(now_ms: i64) -> String {
    let total_seconds = now_ms.div_euclid(1_000);
    let milliseconds = now_ms.rem_euclid(1_000);
    let days = total_seconds.div_euclid(86_400);
    let seconds_of_day = total_seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;

    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{milliseconds:03}Z")
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted_days = days + 719_468;
    let era = if shifted_days >= 0 {
        shifted_days / 146_097
    } else {
        (shifted_days - 146_096) / 146_097
    };
    let day_of_era = shifted_days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_part + 2) / 5 + 1;
    let month = month_part + if month_part < 10 { 3 } else { -9 };
    let year = year + if month <= 2 { 1 } else { 0 };
    (year, month as u32, day as u32)
}

#[derive(Clone, Copy)]
enum JwtExpiration {
    Signed(i64),
    Unsigned(u64),
}

impl JwtExpiration {
    fn is_at_or_before(self, cutoff: i64) -> bool {
        match self {
            Self::Signed(expiration) => expiration <= cutoff,
            Self::Unsigned(expiration) => cutoff >= 0 && expiration <= cutoff as u64,
        }
    }
}

fn jwt_expiration(access_token: &str) -> Option<JwtExpiration> {
    let mut segments = access_token.split('.');
    let _header = segments.next()?;
    let payload = segments.next()?;
    let _signature = segments.next()?;
    if segments.next().is_some() || payload.is_empty() {
        return None;
    }

    let payload = decode_base64url(payload)?;
    let payload = serde_json::from_slice::<Value>(&payload).ok()?;
    let expiration = payload.get("exp")?.as_number()?;
    expiration
        .as_i64()
        .map(JwtExpiration::Signed)
        .or_else(|| expiration.as_u64().map(JwtExpiration::Unsigned))
}

fn decode_base64url(input: &str) -> Option<Vec<u8>> {
    if input.len() % 4 == 1 {
        return None;
    }

    let mut output = Vec::new();
    let mut accumulator = 0_u32;
    let mut bit_count = 0_u8;

    for byte in input.bytes() {
        let value = match byte {
            b'A'..=b'Z' => u32::from(byte - b'A'),
            b'a'..=b'z' => u32::from(byte - b'a' + 26),
            b'0'..=b'9' => u32::from(byte - b'0' + 52),
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        };

        accumulator = (accumulator << 6) | value;
        bit_count += 6;
        if bit_count >= 8 {
            bit_count -= 8;
            output.push((accumulator >> bit_count) as u8);
            accumulator &= if bit_count == 0 {
                0
            } else {
                (1_u32 << bit_count) - 1
            };
        }
    }

    if bit_count != 0 && accumulator != 0 {
        return None;
    }
    Some(output)
}

fn parse_rfc3339_utc(value: &str) -> Option<i128> {
    let bytes = value.as_bytes();
    if bytes.len() < 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return None;
    }

    let year = parse_digits(bytes.get(0..4)?)?;
    let month = parse_digits(bytes.get(5..7)?)?;
    let day = parse_digits(bytes.get(8..10)?)?;
    let hour = parse_digits(bytes.get(11..13)?)?;
    let minute = parse_digits(bytes.get(14..16)?)?;
    let second = parse_digits(bytes.get(17..19)?)?;
    if year == 0
        || month == 0
        || month > 12
        || day == 0
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }

    let fraction = match bytes.get(19) {
        Some(b'Z') if bytes.len() == 20 => &[][..],
        Some(b'.') if bytes.last() == Some(&b'Z') && bytes.len() > 21 => {
            bytes.get(20..bytes.len() - 1)?
        }
        _ => return None,
    };
    if fraction.iter().any(|byte| !byte.is_ascii_digit()) {
        return None;
    }

    let nanoseconds = fraction_nanoseconds(fraction)?;
    let days = days_from_civil(year, month, day);
    let seconds = days.checked_mul(86_400)?
        + i64::from(hour) * 3_600
        + i64::from(minute) * 60
        + i64::from(second);
    Some(i128::from(seconds) * NANOS_PER_SECOND + i128::from(nanoseconds))
}

fn parse_digits(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    bytes.iter().try_fold(0_u32, |value, byte| {
        value
            .checked_mul(10)?
            .checked_add(u32::from(byte.checked_sub(b'0')?))
    })
}

fn fraction_nanoseconds(fraction: &[u8]) -> Option<u32> {
    if fraction.is_empty() {
        return Some(0);
    }
    if fraction.len() > 9 {
        return None;
    }

    let value = parse_digits(fraction)?;
    Some(value * 10_u32.pow(9 - fraction.len() as u32))
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn is_leap_year(year: u32) -> bool {
    year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
}

fn days_from_civil(year: u32, month: u32, day: u32) -> i64 {
    let year = i64::from(year) - if month <= 2 { 1 } else { 0 };
    let era = if year >= 0 {
        year / 400
    } else {
        (year - 399) / 400
    };
    let year_of_era = year - era * 400;
    let month = i64::from(month);
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::{
        CURL_ARGS, ExchangeResponse, REFRESH_MAX_BODY_BYTES, RefreshError, account_identity,
        build_curl_config, escape_curl_config_value, needs_refresh, parse_curl_output,
        refresh_with,
    };

    const NOW_MS: i64 = 1_704_067_200_000;

    #[test]
    fn fresh_jwt_does_not_need_refresh() {
        let auth = br#"{"tokens":{"access_token":"a.eyJleHAiOjE3MDQwNjc1MDF9.b"}}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(false));
    }

    #[test]
    fn expiring_jwt_needs_refresh() {
        let auth = br#"{"tokens":{"access_token":"a.eyJleHAiOjE3MDQwNjc1MDB9.b"}}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(true));
    }

    #[test]
    fn expired_jwt_needs_refresh() {
        let auth = br#"{"tokens":{"access_token":"a.eyJleHAiOjE3MDQwNjc0OTl9.b"}}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(true));
    }

    #[test]
    fn invalid_jwt_falls_back_to_last_refresh() {
        let auth =
            br#"{"tokens":{"access_token":"not-a-jwt"},"last_refresh":"2023-12-31T00:00:00Z"}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(false));
    }

    #[test]
    fn last_refresh_at_eight_days_needs_refresh() {
        let auth =
            br#"{"tokens":{"access_token":"not-a-jwt"},"last_refresh":"2023-12-24T00:00:00Z"}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(true));
    }

    #[test]
    fn recent_last_refresh_does_not_need_refresh() {
        let auth =
            br#"{"tokens":{"access_token":"not-a-jwt"},"last_refresh":"2023-12-24T00:00:01Z"}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(false));
    }

    #[test]
    fn missing_last_refresh_does_not_need_refresh() {
        let auth = br#"{"tokens":{"access_token":"not-a-jwt"}}"#;
        assert_eq!(needs_refresh(auth, NOW_MS), Ok(false));
    }

    #[test]
    fn validates_account_identity() {
        assert_eq!(
            account_identity(br#"{"tokens":{"account_id":" account-1 "}}"#),
            Some("account-1".to_owned())
        );
        assert_eq!(account_identity(br#"{"tokens":{"account_id":""}}"#), None);
        assert_eq!(
            account_identity(br#"{"tokens":{"account_id":"   "}}"#),
            None
        );
        assert_eq!(
            account_identity(br#"{"tokens":{"account_id":"account\n1"}}"#),
            None
        );
        assert_eq!(
            account_identity(br#"{"tokens":{"account_id":"account\r1"}}"#),
            None
        );
        assert_eq!(
            account_identity(br#"{"tokens":{"account_id":"account\u00001"}}"#),
            None
        );
    }

    #[test]
    fn sends_exact_request_with_secret_only_to_callback() {
        let auth = br#"{"tokens":{"account_id":"account-1","refresh_token":"refresh-secret"}}"#;
        let mut callback_calls = 0;
        let result = refresh_with(auth, NOW_MS, |request| {
            callback_calls += 1;
            assert_eq!(
                request,
                br#"{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_token":"refresh-secret"}"#
            );
            let secret = b"refresh-secret";
            assert_eq!(
                request
                    .windows(secret.len())
                    .filter(|window| *window == secret)
                    .count(),
                1
            );
            Ok(ExchangeResponse {
                status: 200,
                body: br#"{"access_token":"new-access"}"#.to_vec(),
            })
        });
        assert!(result.is_ok());
        assert_eq!(callback_calls, 1);
    }

    #[test]
    fn preserves_omitted_optional_and_unknown_fields() {
        let auth = br#"{
            "top_unknown":{"keep":[1,true]},
            "tokens":{
                "account_id":"account-1",
                "refresh_token":"old-refresh",
                "id_token":"old-id",
                "access_token":"old-access",
                "token_unknown":{"nested":"value"}
            },
            "last_refresh":"old"
        }"#;
        let result = refresh_with(auth, NOW_MS, |_| {
            Ok(ExchangeResponse {
                status: 200,
                body: br#"{"access_token":"new-access"}"#.to_vec(),
            })
        });
        let merged: serde_json::Value = match result {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(value) => value,
                Err(_) => panic!("merged JSON should parse"),
            },
            Err(_) => panic!("refresh should succeed"),
        };
        assert_eq!(merged["top_unknown"], serde_json::json!({"keep":[1, true]}));
        assert_eq!(
            merged["tokens"]["token_unknown"],
            serde_json::json!({"nested":"value"})
        );
        assert_eq!(merged["tokens"]["account_id"], "account-1");
        assert_eq!(merged["tokens"]["refresh_token"], "old-refresh");
        assert_eq!(merged["tokens"]["id_token"], "old-id");
        assert_eq!(merged["tokens"]["access_token"], "new-access");
    }

    #[test]
    fn applies_rotated_refresh_token() {
        let auth = br#"{"tokens":{"account_id":"account-1","refresh_token":"old-refresh","id_token":"old-id"}}"#;
        let result = refresh_with(auth, NOW_MS, |_| {
            Ok(ExchangeResponse {
                status: 200,
                body: br#"{"access_token":"new-access","refresh_token":"rotated-refresh"}"#
                    .to_vec(),
            })
        });
        let merged: serde_json::Value = match result {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(value) => value,
                Err(_) => panic!("merged JSON should parse"),
            },
            Err(_) => panic!("refresh should succeed"),
        };
        assert_eq!(merged["tokens"]["refresh_token"], "rotated-refresh");
        assert_eq!(merged["tokens"]["id_token"], "old-id");
        assert_eq!(merged["tokens"]["access_token"], "new-access");
    }

    #[test]
    fn rejects_identity_mismatch_in_direct_and_nested_claims() {
        for payload in [
            r#"{"account_id":"account-2"}"#,
            r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-2"}}"#,
        ] {
            let token = test_jwt(payload);
            let body = format!(r#"{{"id_token":"{token}"}}"#).into_bytes();
            let result = refresh_with(
                br#"{"tokens":{"account_id":"account-1","refresh_token":"refresh-secret"}}"#,
                NOW_MS,
                move |_| Ok(ExchangeResponse { status: 200, body }),
            );
            assert_eq!(result, Err(RefreshError::IdentityMismatch));
        }
    }

    #[test]
    fn rejects_missing_refresh_before_callback() {
        let mut callback_called = false;
        let result = refresh_with(br#"{"tokens":{"account_id":"account-1"}}"#, NOW_MS, |_| {
            callback_called = true;
            Ok(ExchangeResponse {
                status: 200,
                body: br#"{"access_token":"new-access"}"#.to_vec(),
            })
        });
        assert_eq!(result, Err(RefreshError::MissingRefreshToken));
        assert!(!callback_called);
    }

    #[test]
    fn maps_401_to_generic_credential_rejection() {
        let result = refresh_with(
            br#"{"tokens":{"account_id":"account-1","refresh_token":"refresh-secret"}}"#,
            NOW_MS,
            |_| {
                Ok(ExchangeResponse {
                    status: 401,
                    body: b"secret response body".to_vec(),
                })
            },
        );
        assert_eq!(result, Err(RefreshError::CredentialRejected));
    }

    #[test]
    fn rejects_malformed_and_success_empty_responses() {
        let malformed = refresh_with(
            br#"{"tokens":{"account_id":"account-1","refresh_token":"refresh-secret"}}"#,
            NOW_MS,
            |_| {
                Ok(ExchangeResponse {
                    status: 200,
                    body: b"not-json".to_vec(),
                })
            },
        );
        assert_eq!(malformed, Err(RefreshError::InvalidResponse));

        let empty = refresh_with(
            br#"{"tokens":{"account_id":"account-1","refresh_token":"refresh-secret"}}"#,
            NOW_MS,
            |_| {
                Ok(ExchangeResponse {
                    status: 200,
                    body: br#"{"id_token":"","access_token":""}"#.to_vec(),
                })
            },
        );
        assert_eq!(empty, Err(RefreshError::InvalidResponse));
    }

    #[test]
    fn writes_known_millisecond_timestamp() {
        let result = refresh_with(
            br#"{"tokens":{"account_id":"account-1","refresh_token":"refresh-secret"}}"#,
            NOW_MS + 123,
            |_| {
                Ok(ExchangeResponse {
                    status: 200,
                    body: br#"{"access_token":"new-access"}"#.to_vec(),
                })
            },
        );
        let merged: serde_json::Value = match result {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(value) => value,
                Err(_) => panic!("merged JSON should parse"),
            },
            Err(_) => panic!("refresh should succeed"),
        };
        assert_eq!(merged["last_refresh"], "2024-01-01T00:00:00.123Z");
    }

    #[test]
    fn curl_arguments_contain_no_credentials_or_request_data() {
        let args = CURL_ARGS.join(" ");
        assert!(!args.contains("refresh-secret"));
        assert!(!args.contains("app_EMoamEEZ73f0CkXaXp7hrann"));
        assert!(!args.contains("refresh_token"));
        assert!(!args.contains("Authorization"));
    }

    #[test]
    fn curl_config_contains_transport_settings_and_serialized_request() {
        let request = br#"{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_token":"refresh-secret"}"#;
        let config = match build_curl_config(request) {
            Ok(config) => config,
            Err(_) => panic!("valid request should produce curl config"),
        };

        assert!(config.contains("url = \"https://auth.openai.com/oauth/token\""));
        assert!(config.contains("request = \"POST\""));
        assert!(config.contains("header = \"Content-Type: application/json\""));
        assert!(config.contains("connect-timeout = 5"));
        assert!(config.contains("max-time = 12"));
        assert!(config.contains(
            r#"data-raw = "{\"client_id\":\"app_EMoamEEZ73f0CkXaXp7hrann\",\"grant_type\":\"refresh_token\",\"refresh_token\":\"refresh-secret\"}""#
        ));
    }

    #[test]
    fn curl_config_escaping_rejects_unsafe_controls() {
        assert_eq!(
            escape_curl_config_value("slash\\and\"quote"),
            Some("slash\\\\and\\\"quote".to_owned())
        );
        for value in ["line\nfeed", "carriage\rreturn", "nul\0byte"] {
            assert_eq!(escape_curl_config_value(value), None);
        }
    }

    #[test]
    fn curl_output_parser_handles_status_body_and_limits() {
        let parsed = match parse_curl_output(
            br#"{"access_token":"new-access"}
200"#,
        ) {
            Ok(parsed) => parsed,
            Err(_) => panic!("valid curl output should parse"),
        };
        assert_eq!(parsed.status, 200);
        assert_eq!(parsed.body, br#"{"access_token":"new-access"}"#);

        let malformed_outputs = [b"".as_slice(), b"body".as_slice(), b"body\n20x".as_slice()];
        for output in malformed_outputs {
            assert!(matches!(
                parse_curl_output(output),
                Err(RefreshError::RequestFailed)
            ));
        }

        let mut oversized = vec![b'x'; REFRESH_MAX_BODY_BYTES + 1];
        oversized.extend_from_slice(b"\n200");
        assert!(matches!(
            parse_curl_output(&oversized),
            Err(RefreshError::RequestFailed)
        ));
    }

    fn test_jwt(payload: &str) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut encoded = String::new();
        for chunk in payload.as_bytes().chunks(3) {
            let first = chunk[0];
            encoded.push(ALPHABET[(first >> 2) as usize] as char);
            let second = chunk.get(1).copied().unwrap_or(0);
            let third = chunk.get(2).copied().unwrap_or(0);
            encoded.push(ALPHABET[(((first & 0x03) << 4) | (second >> 4)) as usize] as char);
            if chunk.len() > 1 {
                encoded.push(ALPHABET[((second & 0x0f) << 2 | (third >> 6)) as usize] as char);
            }
            if chunk.len() > 2 {
                encoded.push(ALPHABET[(third & 0x3f) as usize] as char);
            }
        }
        format!("header.{encoded}.signature")
    }
}
