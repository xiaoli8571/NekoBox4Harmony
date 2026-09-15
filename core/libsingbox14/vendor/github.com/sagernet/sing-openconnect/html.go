package openconnect

import (
	"strings"

	"golang.org/x/net/html"
)

func findHTMLElement(root *html.Node, name string) *html.Node {
	if root.Type == html.ElementNode && strings.EqualFold(root.Data, name) {
		return root
	}
	for child := root.FirstChild; child != nil; child = child.NextSibling {
		match := findHTMLElement(child, name)
		if match != nil {
			return match
		}
	}
	return nil
}

func htmlAttribute(node *html.Node, name string) (string, bool) {
	for _, attribute := range node.Attr {
		if strings.EqualFold(attribute.Key, name) {
			return attribute.Val, true
		}
	}
	return "", false
}

func htmlText(node *html.Node) string {
	var content strings.Builder
	var walk func(current *html.Node)
	walk = func(current *html.Node) {
		if current.Type == html.TextNode {
			content.WriteString(current.Data)
		}
		for child := current.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(node)
	return content.String()
}
