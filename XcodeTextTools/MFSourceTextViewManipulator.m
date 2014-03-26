//
//  MFSourceTextViewManipulator.m
//  XcodeTextTools
//
//  Created by Michaël Fortin on 2014-03-20.
//  Copyright (c) 2014 Michaël Fortin. All rights reserved.
//

#import "MFSourceTextViewManipulator.h"
#import "NSArray+XcodeTextTools.h"
#import "NSString+XcodeTextTools.h"
#import "NSColor+XcodeTextTools.h"
#import "NSAlert+XcodeTextTools.h"
#import "DVTKit.h"

@interface MFSourceTextViewManipulator ()

@property (readonly, unsafe_unretained) DVTSourceTextView *sourceTextView;
@property (readonly) NSTextStorage *textStorage;

@end

@implementation MFSourceTextViewManipulator
{
	NSUInteger _highlightCount;
	NSMutableArray *_highlightColors;
}

#pragma mark Lifetime

- (id)initWithSourceTextView:(DVTSourceTextView *)textView
{
	self = [super init];
	if (self)
	{
		_sourceTextView = textView;
		
		[self setupHighlightColors];
	}
	return self;
}

- (void)setupHighlightColors
{
	_highlightColors = [@[[NSColor greenColor], [NSColor orangeColor], [NSColor blueColor],
						 [NSColor redColor], [NSColor purpleColor], [NSColor yellowColor],
						 [NSColor brownColor]] mutableCopy];
}

#pragma mark Line Manipulation Helpers

- (NSRange)selectedLinesRange
{
	NSValue *selectedRange = [[self.sourceTextView selectedRanges] firstObject];
	if (!selectedRange) return NSMakeRange(NSNotFound, 0);
	
	return [[self.textStorage string] lineRangeForRange:[selectedRange rangeValue]];
}

- (NSString *)selectedLinesString
{
	NSRange linesRange = [self selectedLinesRange];
	NSString *sourceString = [[self.textStorage attributedSubstringFromRange:linesRange] string];
	NSString *trimmedString = [sourceString stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
	return trimmedString;
}

- (NSArray *)lineRangesFromRanges:(NSArray *)ranges
{
	return [ranges xctt_map:^id(NSValue *range)
	{
		NSRange lineRange = [[self.textStorage string] lineRangeForRange:[range rangeValue]];
		return [NSValue valueWithRange:lineRange];
	}];
}

- (NSArray *)rangesFullyOrPartiallyContainedInSelection:(NSArray *)rangesToFilter
{
	NSMutableArray *rangesOverlappingSelection = [NSMutableArray array];
	for (NSValue *methodDefinitionRange in rangesToFilter)
	{
		NSRange intersection = NSIntersectionRange([methodDefinitionRange rangeValue], [self selectedLinesRange]);
		if (intersection.length > 0) [rangesOverlappingSelection addObject:methodDefinitionRange];
	}
	return rangesOverlappingSelection;
}

- (void)conditionallyChangeTextInRange:(NSRange)range replacementString:(NSString *)replacementString operation:(Block)operation
{
	if (range.location == NSNotFound) return;
	
	// Preserves undo/redo behavior!
	if ([self.sourceTextView shouldChangeTextInRange:range replacementString:replacementString])
	{
		operation();
		[self.sourceTextView didChangeText];
	}
}

- (void)duplicateLines:(NSRange)linesRange
{
	NSString *selectedLinesString = [[self.textStorage attributedSubstringFromRange:linesRange] string];
	
	NSMutableString *insertedString = [[NSMutableString alloc] init];
	
	if ([selectedLinesString xctt_startsWithMethodDefinition])
		[insertedString appendString:@"\n"];
	
	[insertedString appendString:selectedLinesString];
	
	[self insertString:insertedString afterLineRanges:linesRange reindent:NO];
}

- (void)insertString:(NSString *)insertedString afterLineRanges:(NSRange)linesRange reindent:(BOOL)reindent
{
	NSMutableString *stringToInsert = [insertedString mutableCopy];
	
	NSString *selectedLinesString = [self selectedLinesString];
	NSString *trimmedSelectedLinesString = [selectedLinesString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	BOOL emptyLine = [trimmedSelectedLinesString isEqualToString:@""];
	if (!emptyLine && ![stringToInsert hasSuffix:@"\n"]) [stringToInsert appendString:@"\n"];
	
	NSUInteger insertedStringLength = [stringToInsert length];
	NSRange sourceRange = NSMakeRange(linesRange.location + linesRange.length, 0);
	NSUInteger sourceRangeEnd = sourceRange.location + sourceRange.length - (emptyLine ? 1 : 0);
	NSRange finalSelectionRange = NSMakeRange(sourceRangeEnd + insertedStringLength - 1, 0);
	
	[self conditionallyChangeTextInRange:NSMakeRange(sourceRangeEnd - 1, 0) replacementString:stringToInsert operation:^
	{
		[self.textStorage insertAttributedString:[stringToInsert xctt_attributedString] atIndex:sourceRangeEnd];
		[self.sourceTextView setSelectedRange:finalSelectionRange];
		
		if (reindent) [self.sourceTextView indentSelection:self];
	}];
}

#pragma mark Highlighting Helpers

- (void)highlightRanges:(NSArray *)ranges withSameColor:(BOOL)withSameColor
{
	for (NSValue *range in ranges)
	{
		NSString *string = [[self.textStorage string] substringWithRange:[range rangeValue]];
		NSArray *stringRanges = [[self.textStorage string] xctt_rangesOfString:string];
		
		NSColor *highlightColor = [self pushHighlightColor];
		
		for (NSValue *stringRange in stringRanges)
		{
			NSRange range = [stringRange rangeValue];
			[self.textStorage addAttribute:NSBackgroundColorAttributeName value:highlightColor range:range];
		}
	}
}

- (NSColor *)pushHighlightColor
{
	NSColor *color;
	
	if (_highlightCount < [_highlightColors count])
	{
		color = _highlightColors[_highlightCount];
	}
	else
	{
		color = [NSColor xctt_randomColor];
		
		// Add the color to the array of colors so that we can undo highlighting
		// step-by-step afterwards (by enumerating over ranges with those background colors).
		[_highlightColors addObject:color];
	}
	
	_highlightCount++;
	
	return color;
}

- (NSColor *)popHighlightColor
{
	if (_highlightCount == 0) return nil;
	_highlightCount--;
	
	return _highlightColors[_highlightCount];
}

- (void)popAllHighlightColors
{
	_highlightCount = 0;
}

#pragma mark Line Manipulation

- (void)cutLines
{
	[self copyLines];
	[self deleteLines];
}

- (void)copyLines
{
	NSPasteboard *generalPasteboard = [NSPasteboard generalPasteboard];
	[generalPasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
	[generalPasteboard setString:[self selectedLinesString] forType:NSPasteboardTypeString];
}

- (void)pasteLinesWithReindent:(BOOL)reindent
{
	NSMutableString *pasteboardString = [[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] mutableCopy];
	NSRange linesRange = [self selectedLinesRange];
	
	[self insertString:pasteboardString afterLineRanges:linesRange reindent:reindent];
}

- (void)duplicateLines
{
	[self duplicateLines:[self selectedLinesRange]];
}

- (void)deleteLines
{
	NSRange linesRange = [self selectedLinesRange];
	[self conditionallyChangeTextInRange:linesRange replacementString:@"" operation:^
	{
		[self.textStorage deleteCharactersInRange:linesRange];
		[self.sourceTextView moveToRightEndOfLine:self];
	}];
}

#pragma mark Highlighting

- (void)highlightSelectedStrings
{
	[self highlightRanges:[self.sourceTextView selectedRanges] withSameColor:NO];
}

- (void)highlightRegexMatchesWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options
{
	[self highlightRanges:[[self.textStorage string] xctt_rangesOfRegex:pattern options:options] withSameColor:YES];
}

- (void)removeMostRecentlyAddedHighlight
{
	NSColor *highlightColorToRemove = [self popHighlightColor];
	if (!highlightColorToRemove) return;
	
	NSTextStorage *textStorage = self.textStorage;
	NSRange documentRange = NSMakeRange(0, [[textStorage string] length]);
	
	[textStorage enumerateAttribute:NSBackgroundColorAttributeName inRange:documentRange options:0 usingBlock:^(id value, NSRange range, BOOL *stop)
	{
		if ([value isEqual:highlightColorToRemove])
			[textStorage removeAttribute:NSBackgroundColorAttributeName range:range];
	}];
}

- (void)removeAllHighlighting
{
	NSTextStorage *textStorage = self.textStorage;
	NSRange documentRange = NSMakeRange(0, [[textStorage string] length]);
	
	[textStorage enumerateAttribute:NSBackgroundColorAttributeName inRange:documentRange options:0 usingBlock:^(id value, NSRange range, BOOL *stop)
	{
		[textStorage removeAttribute:NSBackgroundColorAttributeName range:range];
	}];
	
	[self popAllHighlightColors];
}

#pragma mark Selection

- (void)selectMethods
{
	NSArray *methodDefinitionRanges = [[self.textStorage string] xctt_methodDefinitionRanges];
	NSArray *rangesToSelect = [self rangesFullyOrPartiallyContainedInSelection:methodDefinitionRanges];
	
	if ([rangesToSelect count] > 0)
		[self.sourceTextView setSelectedRanges:rangesToSelect affinity:NSSelectionAffinityUpstream stillSelecting:NO];
}

- (void)selectMethodSignatures
{
	NSArray *methodDefinitionRanges = [[self.textStorage string] xctt_methodDefinitionRanges];
	NSArray *selectedMethodDefinitionRanges = [self rangesFullyOrPartiallyContainedInSelection:methodDefinitionRanges];
	NSArray *methodSignatureRanges = [[self.textStorage string] xctt_methodSignatureRanges];
	
	NSMutableArray *rangesToSelect = [NSMutableArray array];
	for (NSValue *methodSignatureRange in methodSignatureRanges)
	{
		for (NSValue *selectedMethodDefinitionRange in selectedMethodDefinitionRanges)
		{
			if (NSIntersectionRange([methodSignatureRange rangeValue], [selectedMethodDefinitionRange rangeValue]).length != 0)
				[rangesToSelect addObject:methodSignatureRange];
		}
	}
	
	if ([rangesToSelect count] > 0)
		[self.sourceTextView setSelectedRanges:rangesToSelect affinity:NSSelectionAffinityUpstream stillSelecting:NO];
}

- (void)duplicateMethods
{
	NSArray *methodDefinitionRanges = [[self.textStorage string] xctt_methodDefinitionRanges];
	NSArray *selectedMethodDefinitionRanges = [self rangesFullyOrPartiallyContainedInSelection:methodDefinitionRanges];
	NSArray *selectedMethodDefinitionLineRanges = [self lineRangesFromRanges:selectedMethodDefinitionRanges];
	
	if ([selectedMethodDefinitionLineRanges count] == 0) return;
	
	NSRange unionRange = [selectedMethodDefinitionLineRanges[0] rangeValue];
	for (NSValue *range in selectedMethodDefinitionLineRanges)
		unionRange = NSUnionRange(unionRange, [range rangeValue]);
	
	[self duplicateLines:unionRange];
}
	
- (void)pasteMethodDeclarations
{
	NSMutableString *pasteboardString = [[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] mutableCopy];
	NSString *methodDeclarations = [pasteboardString xctt_extractMethodDeclarations];
	[self insertString:methodDeclarations afterLineRanges:[self selectedLinesRange] reindent:YES];
}

#pragma mark Accessor Overrides

- (NSTextStorage *)textStorage
{
	return [self.sourceTextView textStorage];
}

@end