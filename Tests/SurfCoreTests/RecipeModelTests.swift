import Testing

@testable import SurfCore

@Suite("Recipe parsing")
struct RecipeParsingTests {

    /// The shape most real sites ship: a @graph, the recipe buried among
    /// Organization and WebPage nodes, entities in the strings.
    private let graphJSON = """
    {
      "@context": "https://schema.org",
      "@graph": [
        { "@type": "Organization", "name": "Sea Journal Kitchen" },
        {
          "@type": "Recipe",
          "name": "Mariner&#39;s Chowder",
          "description": "A chowder for cold watches. <b>Rich</b> &amp; warming.",
          "author": { "@type": "Person", "name": "A. Mariner" },
          "image": ["https://example.com/chowder.jpg"],
          "recipeYield": ["6", "6 servings"],
          "prepTime": "PT20M",
          "cookTime": "PT1H10M",
          "totalTime": "PT1H30M",
          "recipeIngredient": [
            "1 1/2 cups heavy cream",
            "2 lbs cod, cut into chunks",
            "\\u00bd cup white wine",
            "salt to taste"
          ],
          "recipeInstructions": [
            { "@type": "HowToStep", "text": "Render the salt pork over low heat." },
            {
              "@type": "HowToSection",
              "name": "For the broth",
              "itemListElement": [
                { "@type": "HowToStep", "text": "Add the wine &amp; reduce by half." },
                { "@type": "HowToStep", "text": "Add cream; never boil it." }
              ]
            }
          ]
        }
      ]
    }
    """

    @Test("A @graph-wrapped recipe parses whole")
    func graphRecipe() throws {
        let recipe = try #require(FocusRecipe.parse(fromJSONLD: [graphJSON]))
        #expect(recipe.title == "Mariner's Chowder")
        #expect(recipe.summary == "A chowder for cold watches. Rich & warming.")
        #expect(recipe.author == "A. Mariner")
        #expect(recipe.image == "https://example.com/chowder.jpg")
        #expect(recipe.yieldText == "6 servings")
        #expect(recipe.servings == 6)
        #expect(recipe.prepMinutes == 20)
        #expect(recipe.cookMinutes == 70)
        #expect(recipe.totalMinutes == 90)
        #expect(recipe.ingredients.count == 4)
        #expect(recipe.isSubstantial)
    }

    @Test("Sections keep their names and steps flatten in order")
    func sectionedSteps() throws {
        let recipe = try #require(FocusRecipe.parse(fromJSONLD: [graphJSON]))
        #expect(recipe.steps.map(\.text) == [
            "Render the salt pork over low heat.",
            "Add the wine & reduce by half.",
            "Add cream; never boil it.",
        ])
        #expect(recipe.steps.map(\.section) == ["", "For the broth", "For the broth"])
    }

    @Test("Legacy keys and bare-string instructions still parse")
    func legacyShapes() throws {
        let json = """
        {
          "@type": ["Recipe", "NewsArticle"],
          "name": "Toast",
          "recipeYield": 2,
          "ingredients": ["2 slices bread", "1 tbsp butter", "1 pinch salt"],
          "recipeInstructions": "Toast the bread.\\nButter it.\\nSalt it."
        }
        """
        let recipe = try #require(FocusRecipe.parse(fromJSONLD: [json]))
        #expect(recipe.yieldText == "2 servings")
        #expect(recipe.ingredients.count == 3)
        #expect(recipe.steps.map(\.text) == ["Toast the bread.", "Butter it.", "Salt it."])
    }

    /// The gate that keeps SEO stubs from claiming the lens.
    @Test("A hollow recipe is not offered")
    func hollowRecipe() {
        let stub = """
        { "@type": "Recipe", "name": "Water", "recipeIngredient": ["water"],
          "recipeInstructions": "Pour." }
        """
        #expect(FocusRecipe.parse(fromJSONLD: [stub]) == nil)
    }

    @Test("Broken JSON in one script doesn't cost the recipe in the next")
    func brokenScriptSkipped() {
        let recipe = FocusRecipe.parse(fromJSONLD: ["{not json", graphJSON])
        #expect(recipe != nil)
    }

    @Test("ISO durations, including the awkward ones")
    func durations() {
        #expect(FocusRecipe.minutes(fromISODuration: "PT30M") == 30)
        #expect(FocusRecipe.minutes(fromISODuration: "PT1H") == 60)
        #expect(FocusRecipe.minutes(fromISODuration: "PT1H30M") == 90)
        #expect(FocusRecipe.minutes(fromISODuration: "P1DT2H") == 1560)
        #expect(FocusRecipe.minutes(fromISODuration: "PT90S") == 2)
        #expect(FocusRecipe.minutes(fromISODuration: "PT0M") == nil)
        #expect(FocusRecipe.minutes(fromISODuration: "") == nil)
        #expect(FocusRecipe.minutes(fromISODuration: nil) == nil)
        #expect(FocusRecipe.minutes(fromISODuration: "an hour") == nil)
    }

    @Test("Duration labels read like a cook wrote them")
    func durationLabels() {
        #expect(FocusRecipe.label(forMinutes: 45) == "45 min")
        #expect(FocusRecipe.label(forMinutes: 60) == "1 hr")
        #expect(FocusRecipe.label(forMinutes: 90) == "1 hr 30 min")
    }
}

@Suite("Ingredient quantities")
struct RecipeIngredientTests {

    private func quantity(_ line: String) -> Double? {
        RecipeIngredient.parseQuantity(from: line).quantity
    }

    @Test("The forms recipe lines actually use")
    func quantityForms() {
        #expect(quantity("2 cups flour") == 2)
        #expect(quantity("1.5 cups milk") == 1.5)
        #expect(quantity("1 1/2 cups cream") == 1.5)
        #expect(quantity("3/4 tsp salt") == 0.75)
        #expect(quantity("½ cup wine") == 0.5)
        #expect(quantity("1½ cups stock") == 1.5)
        #expect(quantity("salt to taste") == nil)
        #expect(quantity("a pinch of nutmeg") == nil)
    }

    @Test("The remainder is the line minus its quantity")
    func remainder() {
        let parsed = RecipeIngredient.parseQuantity(from: "1 1/2 cups cream, cold")
        #expect(parsed.remainder == "cups cream, cold")
    }

    @Test("Scaling rewrites the number and nothing else")
    func scaling() {
        let cream = RecipeIngredient(text: "1 1/2 cups heavy cream")
        #expect(cream.scaled(by: 2) == "3 cups heavy cream")
        #expect(cream.scaled(by: 0.5) == "¾ cups heavy cream")
        #expect(cream.scaled(by: 1) == "1 1/2 cups heavy cream")

        let salt = RecipeIngredient(text: "salt to taste")
        #expect(salt.scaled(by: 3) == "salt to taste")
    }

    @Test("Scaled numbers come back as cook's fractions")
    func formatting() {
        #expect(RecipeIngredient.format(0.5) == "½")
        #expect(RecipeIngredient.format(1.5) == "1½")
        #expect(RecipeIngredient.format(2.25) == "2¼")
        #expect(RecipeIngredient.format(3) == "3")
        #expect(RecipeIngredient.format(2.0 / 3) == "⅔")
        // Nothing clean: a short decimal, not 0.6666666.
        #expect(RecipeIngredient.format(1.7) == "1.7")
    }
}
