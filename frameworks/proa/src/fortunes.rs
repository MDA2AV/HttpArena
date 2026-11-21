use proa::{DataLoader, WebContext, WebRenderSync, WriteBuf, WriteError, html_sync};

pub struct Fortune<'a> {
    pub id: i32,
    pub message: &'a str,
}

pub struct Fortunes<'a>(pub &'a [Fortune<'a>]);

impl<L: DataLoader, B: WriteBuf> WebRenderSync<L, B> for Fortunes<'_> {
    fn render(self, cx: &mut WebContext<L, B>) -> Result<(), WriteError> {
        html_sync! {
            <!DOCTYPE html>
            <html lang="en">
                <head>
                    <title>"Fortunes"</title>
                </head>
                <body data-component="fortunes">
                    <table>
                        <tr>
                            <th>"id"</th>
                            <th>"message"</th>
                        </tr>
                        {for fortune in self.0 {
                            html_sync! {
                                <tr><td>{fortune.id}</td><td>{fortune.message}</td></tr>
                            }
                        }}
                    </table>
                </body>
            </html>
        }
        .render(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::{Fortune, Fortunes};
    use proa::{WebContext, WebRenderSync};

    #[test]
    fn escapes_database_text_and_renders_numeric_ids() {
        let rows = [Fortune {
            id: 42,
            message: "<script>&",
        }];
        let mut context = WebContext::with_buffer(Vec::new());
        Fortunes(&rows).render(&mut context).unwrap();
        let output = String::from_utf8(context.into_output()).unwrap();
        assert!(output.contains("<td>42</td><td>&lt;script&gt;&amp;</td>"));
    }
}
