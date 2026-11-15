//! Finding chats by name as the user types: a chat matches when its name holds every word of the
//! query, ignoring case and accents ("cafe" finds "Café Club").

use std::sync::Arc;

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

use crate::chat::Chat;

/// The chats whose name holds every word of `query`, in their order. A query with no words
/// matches every chat.
pub fn find_chats<'a>(
    chats: impl IntoIterator<Item = &'a Arc<Chat>>,
    query: &str,
) -> impl Iterator<Item = &'a Arc<Chat>> {
    let words: Vec<String> = words(query).collect();
    chats.into_iter().filter(move |chat| {
        let name = folded(&chat.name);
        words.iter().all(|word| name.contains(word.as_str()))
    })
}

/// The query's words, folded: what is between the characters that are neither letters nor digits.
pub(crate) fn words(query: &str) -> impl Iterator<Item = String> {
    query
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(folded)
}

/// `text` in lower case, without its accents.
pub(crate) fn folded(text: &str) -> String {
    text.nfd()
        .filter(|character| !is_combining_mark(*character))
        .flat_map(char::to_lowercase)
        .collect()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::find_chats;
    use crate::chat::{Chat, Folder};
    use crate::network::Network;

    fn chats(names: &[&str]) -> Vec<Arc<Chat>> {
        names
            .iter()
            .enumerate()
            .map(|(index, name)| {
                Arc::new(Chat {
                    id: format!("!{index}:test").into(),
                    name: (*name).to_owned(),
                    preview: None,
                    date: None,
                    unread_count: 0,
                    is_marked_unread: false,
                    is_muted: false,
                    network: Network::Matrix,
                    avatar: None,
                    member_avatars: Vec::new(),
                    reminder: None,
                    is_group: false,
                    folder: Folder::Inbox,
                    pinned: None,
                    rooms: Vec::new(),
                    default_room: None,
                })
            })
            .collect()
    }

    fn found(chats: &[Arc<Chat>], query: &str) -> Vec<String> {
        find_chats(chats, query).map(|chat| chat.name.clone()).collect()
    }

    #[test]
    fn every_word_must_be_in_the_name_in_any_case_and_order() {
        let chats = chats(&["Anna Nováková", "Anna Smith", "Team Lunch"]);
        assert_eq!(found(&chats, "smith ANNA"), ["Anna Smith"]);
        assert_eq!(found(&chats, "lunch, team!"), ["Team Lunch"]);
    }

    #[test]
    fn accents_do_not_matter_on_either_side() {
        let chats = chats(&["Anna Nováková", "Café Club"]);
        assert_eq!(found(&chats, "novakova"), ["Anna Nováková"]);
        assert_eq!(found(&chats, "cafè"), ["Café Club"]);
    }

    #[test]
    fn a_query_with_no_words_finds_every_chat_in_order() {
        let chats = chats(&["B", "A"]);
        assert_eq!(found(&chats, " - "), ["B", "A"]);
    }
}
